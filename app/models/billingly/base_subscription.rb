module Billingly
  require 'has_duration'
 
  # A customer will always have at least one subscription to your application.
  # Everytime there is a change in a {Customer customer's} subscription, the current one
  # is terminated immediately and a new one is created.
  #
  # For example, changing a {Plan} consists on terminating the current
  # subscription and creating a new one for the new plan.
  # Also, a new subscription is created when {Customer customers} reactivate their accounts
  # after being deactivated.
  #
  # The most recent subscription is the one currently being charged for, unless the customer
  # is deactivated at the moment, in which case the last subscription should not be considered
  # to be active.
  class BaseSubscription < ActiveRecord::Base
    self.abstract_class = true
    self.table_name = 'billingly_subscriptions'
  
    has_many :ledger_entries, foreign_key: :subscription_id

    # The date in which this subscription started.
    # This subscription's first invoice will have it's period_start date
    # matching the date in which the subscription started.
    # @property subscribed_on
    # @return [DateTime]
    validates :subscribed_on, presence: true
    
    # Subscriptions are terminated for a reason which could be:
    #   * trial_expired: Subscription was a trial and it just expired.
    #   * debtor: The customer owed an invoice for this subscription and did not pay.
    #   * changed_subscription: This subscription was immediately replaced by another one.
    #   * left_voluntarily: This subscription was terminated because the customer left.
    #
    # TERMINATION_REASONS are important for auditing and for the mailing tasks to notify
    # about subscriptions terminated automatically by the system.
    TERMINATION_REASONS = %w(trial_expired debtor changed_subscription left_voluntarily)

    # The date in which this subscription ended.
    #
    # Every ended subscription ended for a reason, look at {TERMINATION_REASONS}.
    # @property unsubscribed_on
    # @return [DateTime]
    validates :unsubscribed_on, presence: true, if: :unsubscribed_because

    # The reason why this subscription ended.
    #
    # Every ended subscription ended for a reason, look at {TERMINATION_REASONS}.
    # @property unsubscribed_because
    # @return [DateTime]
    validates :unsubscribed_because, inclusion: TERMINATION_REASONS, if: :terminated?

    # Was this subscription terminated?
    # @property [r] terminated?
    # @return [Boolean] Whether the subscription was terminated or not.
    def terminated?
      not unsubscribed_on.nil?
    end
    
    # The grace period we use when calculating an invoices due date.
    # If a subscription is payable_upfront, then the customer effectively owes us
    # since the day in which a given period starts.
    # 
    # If a subscription is payable on 'due-month', then the customer effectively
    # owes us money since the date in which a given period ended.
    #
    # When we invoice for a given period we will set the due_date a few days
    # ahead of the date in which the debt was made effective, we call this
    # a grace_period.
    #
    # @property grace_period
    # @return [ActiveSupport::Duration] It's what you get by doing '1.month', '10.days', etc.
    has_duration :grace_period
    validates :grace_period, presence: true
    
    # A subscription can be a free trial, ending on the date stored in `is_trial_expiring_on'.
    # Free trial subscriptions don't have {Invoice invoices}. The {Customer customer} is required
    # to subscribe to a non-trial plan before the trial subscription expires.
    #
    # The {#trial?} convenience method returns wheter this subscription is a trial or not.
    #
    # @property is_trial_expiring_on
    # @return [DateTime] 
    
    # When a subscription was started from a {Plan} a reference to the plan is saved.
    # Although, all the plan's fields are denormalized in this subscription.
    #
    # If the subscription was not started from a plan, then this will be nil.
    #
    # @property plan
    # @return [Billingly::Plan, nil] 
    belongs_to :plan
    
    # (see #is_trial_expiring_on)
    # @property [r] trial?
    # @return [Boolean]
    def trial?
      not is_trial_expiring_on.nil?
    end

    # Some subscriptions have a setup fee, or an initial discount.
    # For billingly, this is considered a signup_price. If set, then the first invoice
    # to be generated for this subscription will be for the amount specified in signup_price
    # instead of {#amount}
    #
    # A signup_price can also be specified on a {Billingly::Plan Plan} and will be copied
    # over to the subscription when subscribing to it.
    # @property signup_price
    # @return [BigDecimal]

    # Invoices will be generated before their due_date, as soon as possible,
    # but not sooner than GENERATE_AHEAD days.
    GENERATE_AHEAD = 3.days

    belongs_to :customer
    has_many :invoices, foreign_key: :subscription_id
   
    has_duration :periodicity
    validates :periodicity, presence: true

    # The invoice generation process should run frequently, at least on a daily basis.
    # It will create invoices some time before they are due, to give customers a chance
    # to pay and settle them.
    # If there is any {#signup_price} then the first invoice will be for that amount
    # instead of the regular amount.
    # This method is idempotent, if an upcoming invoice for a subscription already exists,
    # it does not create yet another one.
    def generate_next_invoice
      return if terminated?
      return if trial?
      from = invoices.empty? ? subscribed_on : invoices.last.period_end
      to = from + periodicity
      due_on = (payable_upfront ? from : to) + grace_period
      return if GENERATE_AHEAD.from_now < from

      payable_amount = (invoices.empty? && signup_price) ? signup_price : amount
      
      invoice = invoices.create!(customer: customer, amount: payable_amount,
        due_on: due_on, period_start: from, period_end: to)
      invoice.charge
      return invoice
    end
    
    # Terminates this subscription, it could be either because we deactivate a debtor
    # or because the customer decided to end his subscription on his own terms.
    #
    # Use the shortcuts:
    #   {#terminate_left_voluntarily}, {#terminate_trial_expired},
    #   {#terminate_debtor}, {#terminate_changed_subscription}
    # 
    # Once terminated, a subscription cannot be re-open, just create a new one.
    # @param reason [Symbol] the reason to terminate this subscription, see {TERMINATION_REASONS}
    # @return [self, nil] nil if the account was already terminated, self otherwise.
    def terminate(reason)
      return if terminated?
      self.unsubscribed_on = Time.now
      self.unsubscribed_because = reason
      invoices.last.truncate unless trial?
      save!
      on_terminated
      return self
    end

    TERMINATION_REASONS.each do |reason|
      define_method("terminate_#{reason}") do
        terminate(reason)
      end
    end
    
    # When a trial subscription ends the customer is notified about it via email.
    # @return [self, nil] not nil means the notification was sent successfully.
    def notify_trial_expired
      return unless trial?
      return unless terminated? && unsubscribed_because == 'trial_expired'
      return unless notified_trial_expired_on.nil?
      return if customer.do_not_email?
      Billingly::Mailer.trial_expired_notification(self).deliver!
      update_attribute(:notified_trial_expired_on, Time.now)
      return self
    end

    # When a trial subscription about to end, the customer is notified about it via email.
    # @return [self, nil] not nil means the notification was sent successfully.
    def notify_trial_will_expire
      return unless trial?
      # return unless terminated? && unsubscribed_because == 'trial_expired'
      return unless notified_trial_will_expire_on.nil?
      return if customer.do_not_email?
      Billingly::Mailer.trial_will_expire_notification(self).deliver!
      update_attribute(:notified_trial_will_expire_on, Time.now)
      return self
    end

    # provide your own callback
    def on_terminated
      
    end
  end
end
