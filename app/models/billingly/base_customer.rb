require 'validates_email_format_of'

module Billingly

  # A {Customer} is Billingly's main actor.
  # * Customers have a {Subscription} to your service which entitles them to use it.
  # * Customers are {Invoice invoiced} regularly to pay for their {Subscription}
  # * {Payment Payments} are received on a {Customer}s behalf and credited to their account.
  # * Invoices are generated periodically calculating charges a Customer incurred in.
  # * Receipts are sent to Customers when their invoices are paid.
  class BaseCustomer < ActiveRecord::Base
    self.abstract_class = true
    self.table_name = 'billingly_customers'

    # The reason why this customer is deactivated.
    # A customer can be deactivated for one of 3 reasons:
    #   * trial_expired: Their trial period expired.
    #   * debtor: They have unpaid invoices.
    #   * left_voluntarily: They decided to leave the site.
    # This is important when reactivating their account. If they left in their own terms,
    # we won't try to reactivate their account when we receive a payment from them.
    # The message shown to them when they reactivate will also be different depending on
    # how they left.
    DEACTIVATION_REASONS = %w(trial_expired debtor left_voluntarily)

    # The Date and Time in which the Customer's account was deactivated (see {#deactivated?}).
    # This field denormalizes the date in which this customer's last subscription was ended.
    # @!attribute [r] deactivated_since
    # @return [DateTime]
    validates :deactivated_since, presence: true, if: :deactivation_reason

    # (see Customer::DEACTIVATION_REASONS)
    # @return [String]
    # @!attribute deactivation_reason
    validates :deactivation_reason, inclusion: DEACTIVATION_REASONS, if: :deactivated?

    # A customer can be {#deactivate deactivated} when they cancel their subscription
    # or when they miss a payment. Under the hood this function checks the
    # {#deactivated_since} attribute.
    # @!attribute [r] deactivated?
    def deactivated?
      not deactivated_since.nil?
    end

    # Used as contact address, validates format but does not check uniqueness.
    # @!attribute email
    # @return [String]
    attr_accessible :email
    validates_email_format_of :email

    # All subscriptions this customer was ever subscribed to.
    # @!attribute subscriptions
    # @return [Array<Subscription>]
    has_many :subscriptions, foreign_key: 'customer_id'

    # All paymetns that were ever credited for this customer
    # @!attribute payments
    # @return [Array<Payment>]
    has_many :payments, foreign_key: 'customer_id'

    # The {Subscription} for which the customer is currently being charged.
    # @!attribute [r] active_subscription
    # @return [Subscription, nil]
    def active_subscription
      last = subscriptions.last
      last unless last.nil? || last.terminated?
    end

    # (see Customer.debtors)
    # @!attribute [r] debtor?
    # @return [Boolean] whether this customer is a debtor or not.
    def debtor?
      not self.class.debtors.find_by_id(self.id).nil?
    end

    # All {Invoice invoices} ever created for this customer, for any {Subscription}
    # @!attribute invoices
    # @return [Array<Invoice>]
    has_many :invoices, foreign_key: 'customer_id'

    # Every {JournalEntry} ever created for this customer, a {#ledger} is created from these.
    # See {JournalEntry} for a description on what they are.
    # @!attribute journal_entries
    # @return [Array<JournalEntry>]
    has_many :journal_entries, foreign_key: 'customer_id'

    # (see Customer::DEACTIVATION_REASONS)
    # @return [Symbol]
    # @!attribute deactivation_reason
    validates :deactivation_reason, inclusion: DEACTIVATION_REASONS, if: :deactivated?

    # Whether the user is on an unfinished trial period.
    # @!attribute [r] doing_trial?
    # @return [Boolean]
    def doing_trial?
      active_subscription && active_subscription.trial?
    end

    # When the user is doing a trial, this would be how many days are left until it's over.
    # @!attribute [r] trial_days_left
    # @return [Integer]
    def trial_days_left
      return unless doing_trial?
      (active_subscription.is_trial_expiring_on.to_date - Time.now.utc.to_date).to_i
    end

    # Customers subscribe to the service under certain conditions referred to as a {Plan},
    # and perform periodic payments to continue using it.
    # We offer common plans stating how much and how often they should pay, also, if the
    # payment is to be done at the beginning or end of the period (upfront or due-month)
    # Every customer can potentially get a special deal, but we offer common
    # deals as {Plan Plans} from which a proper {Subscription} is created.
    # A {Subscription} is also an acceptable argument, in that case the new one
    # will maintain all the characteristics of that one, except the starting date.
    # @param [Plan, Subscription]
    # @return [Subscription] The newly created {Subscription}
    def subscribe_to_plan(plan, is_trial_expiring_on = nil)
      before_subscribe_to_plan(plan)
      subscription = nil
      begin
        transaction do
          subscriptions.last.terminate_changed_subscription if subscriptions.last
          subscription = subscriptions.build.tap do |new|
            [:payable_upfront, :description, :periodicity,
             :amount, :grace_period, :signup_price].each do |k|
              new[k] = plan[k]
            end
            new.plan = plan if plan.is_a?(Billingly::Plan)
            new.is_trial_expiring_on = is_trial_expiring_on
            new.subscribed_on = Time.now
            new.save!
            new.generate_next_invoice
            on_subscription_success
          end
          self.deactivated_since = nil
          self.deactivation_reason = nil
          self.save!
        end
      rescue Exception => e
        Rails.logger.info e
        Rails.logger.info e.message
        Rails.logger.info e.backtrace
        raise e
      end
      return subscription
    end

    # Customers can subscribe to a plan using a special subscription code which would
    # allow them to access an otherwise hidden plan.
    # The {SpecialPlanCode} can also contain an amount to be redeemed.
    # @param code [SpecialPlanCode] The code being redeemed.
    def redeem_special_plan_code(code)
      return if code.redeemed?
      credit_payment(code.bonus_amount) if code.bonus_amount
      subscribe_to_plan(code.plan)
      code.update_attributes(customer: self, redeemed_on: Time.now)
    end

    # Callback called whenever this customer is successfully subscribed to a plan.
    # This callback does not differentiate if the customer is subscribing for the first time,
    # reactivating his account or just changing from one plan to another.
    # self.active_subscription will be the current subscription when this method is called.
    def on_subscription_success
    end

    def before_subscribe_to_plan(plan)
    end

    # Creates a general ledger from {JournalEntry journal entries}.
    # Every {Invoice} and {Payment} involves movements to the customer's account.
    # which are registered as a {JournalEntry}.
    # The ledger can tell us whats the cash balance
    # in our customer's favor and how much money have they paid overall.
    # @see JournalEntry
    # @return [{Symbol => BigDecimal}]
    # @todo Due to silly rounding errors on sqlite this implementation needs
    #       to convert decimals to float and then to decimals again. :S
    def ledger
      Hash.new(0.0).tap do |all|
        journal_entries.group_by(&:account).collect do |account, entries|
          values = entries.collect(&:amount).collect(&:to_f)
          all[account.to_sym] = values.inject(0.0) do |sum,item|
            (BigDecimal.new(sum.to_s) + BigDecimal.new(item.to_s)).to_f
          end
        end
      end
    end

    # Shortcut for adding {#journal_entries} for this customer.
    # @note Most likely, you will never add entries to the customer journal yourself.
    #       These are created when {Invoice invoicing} or crediting {Payment payments}
    def add_to_journal(amount, *accounts, extra)
      accounts = [] if accounts.nil?
      unless extra.is_a?(Hash)
        accounts << extra
        extra = {}
      end

      accounts.each do |account|
        journal_entries.create!(extra.merge(amount: amount, account: account.to_s))
      end
    end

    # A customer who has overdue invoices at the time of asking this question is
    # considered a debtor.
    #
    # @note
    #   A customer may be a debtor and still have an active account until Billingly's
    #   rake task goes through the process of {#deactivate_all_debtors deactivating all debtors}.
    #
    #   Furthermore, customers may unsubscribe before their {Invoice invoices} become overdue,
    #   hence they may be in a deactivated state and not be debtors yet.
    def self.debtors
       joins(:invoices).readonly(false)
        .where("#{Billingly::Invoice.table_name}.due_on < ?", Time.now)
        .where(billingly_invoices: {deleted_on: nil, paid_on: nil})
    end

    # Credits an amount of money to customer's account and then triggers the corresponding
    # actions if a {Payment payment} was expected from this customer.
    #
    # Apart from creating a {Payment} object this method will try to charge pending invoices
    # and reactivate a customer who was deactivated for being a debtor.
    #
    # @note
    #   This is the single point of entry for {Payment Payments}.
    #
    #   If you're processing payments using {http://activemerchant.org} you should hook
    #   your 'Incoming Payment Notifications' to call this method to credit the received
    #   amount to the customer's account.
    #
    # @param amount [BigDecimal, float] the amount to be credited.
    def credit_payment(amount)
      Billingly::Payment.credit_for(self, amount)
      charge_pending_invoices
      reactivate if deactivated? && deactivation_reason == 'debtor'
    end

    # Terminate a customer's subscription to the service.
    # Customers are deactivated due to lack of payment, because they decide to end their
    # subscription to your service or because their trial period expired.
    #
    # Use the shortcuts:
    #   {#deactivate_left_voluntarily}, {#deactivate_trial_expired} or {#deactivate_debtor}
    #
    # Deactivated customers can always be {#reactivate reactivated} later.
    # @param reason [Symbol] the deactivation reason, see {DEACTIVATION_REASONS}
    # @return [self, nil] nil if the account was already deactivated, self otherwise.
    def deactivate(reason)
      return if deactivated?
      active_subscription.terminate(reason)
      self.deactivated_since = Time.now
      self.deactivation_reason = reason
      save!
      return self
    end

    DEACTIVATION_REASONS.each do |reason|
      define_method("deactivate_#{reason}") do
        deactivate(reason.to_sym)
      end
    end

    # @see #deactivate
    def deactivate_left_voluntarily
      deactivate('left_voluntarily')
    end

    # @see #deactivate
    def deactivate_trial_expired
      deactivate('trial_expired')
    end

    # @see #deactivate
    def deactivate_debtor
      deactivate('debtor')
    end

    # Customers whose account has been {#deactivate deactivated} can always re-join the service
    # as long as they {#debtor? don't owe any money}
    # @return [self, nil] nil if the customer could not be reactivated, self otherwise.
    def reactivate(new_plan = nil)
      new_plan = new_plan || subscriptions.last
      return if new_plan.nil?
      return unless deactivated?
      return if debtor?
      self.deactivated_since = nil
      self.deactivation_reason = nil
      self.save!(validate: false)
      # update_attribute(:deactivated_since, nil)
      subscribe_to_plan(new_plan)
      return self
    end

    # Charges all invoices for which the customer has enough balance.
    # Oldest invoices are charged first, newer invoices should not be charged until
    # the oldest ones are paid.
    #
    # See {Billingly::Invoice#charge Invoice#charge} for more information
    # on how invoices are charged from the customer's balance.
    def charge_pending_invoices
      invoices.where(deleted_on: nil, paid_on: nil).order('period_start')
        .each{|invoice| break unless invoice.charge}
    end

    # Can this customer subscribe to a plan?.
    # You may want to prevent customers from upgrading or downgrading to other plans
    # depending on their usage of your service.
    #
    # This method is only used in views and controllers to prevent customers from requesting
    # to be upgraded or downgraded to a plan without your consent.
    # The model layer can still subscribe the customer if you so desire.
    #
    # The default implementation lets Customers upgrade to any if they are currently doing
    # a trial period, and it does not let them re-subscribe to the same plan afterwards.
    # It also always disallows debtors to subscribe to another plan.
    # @param plan [Billingly::Plan]
    def can_subscribe_to?(plan)
      return false if !doing_trial? && active_subscription && active_subscription.plan == plan
      return false if debtor?
      return true
    end

    # Some customers do not want to be bothered via email, which is understandable.
    # You can override this method to decide which customers should never be emailed
    # with invoices, receipts or when their trial is over.
    #
    # It is false by default, this means all of your customers will be emailed.
    # @return [Boolean] whether this customer opted out from receiving emails.
    def do_not_email?
      false
    end

  end
end
