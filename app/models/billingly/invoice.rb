module Billingly
  class Invoice < ActiveRecord::Base
    belongs_to :subscription
    belongs_to :customer
    has_many :journal_entries 
    attr_accessible :customer, :amount, :due_on, :period_start, :period_end
    before_create :generate_code
    
    def paid?
      not paid_on.nil?
    end
    
    def deleted?
      not deleted_on.nil?
    end
    
    # Settle an invoice by moving money from the cash balance into an expense,
    # after charged the invoice becomes paid.
    def charge
      return if paid?
      return unless deleted_on.nil?
      return if period_start > Time.now
      return if customer.ledger[:cash] < amount
      
      update_attribute(:paid_on, Time.now)
      extra = {invoice: self, subscription: subscription}
      customer.add_to_journal(-(amount), :cash, extra)
      customer.add_to_journal(amount, :spent, extra)
      
      return self
    end
    
    # When a subscription terminates, it's last invoice gets truncated so that it does
    # not extend beyond the duration of the subscription.
    def truncate
      return if Time.now > self.period_end
      old_amount = self.amount
      new_amount = if self.period_start < Time.now 
        whole_period = self.period_end - self.period_start
        used_period = Time.now - self.period_start
        self.period_end = Time.now
        used_period.round * old_amount / whole_period.round
      else
        self.deleted_on = Time.now
        0
      end
      self.amount = BigDecimal.new(new_amount.round(2).to_s)
      if paid?
        reimburse = (old_amount - self.amount).round(2)
        extra = {invoice: self, subscription: subscription}
        customer.add_to_journal(reimburse, :cash, extra)
        customer.add_to_journal(-(reimburse), :spent, extra)
      end
      save!
      self.charge
      return self
    end

    def notify_pending
      return unless notified_pending_on.nil?
      return if paid?
      return if deleted?
      return if customer.do_not_email?
      return if due_on > subscription.grace_period.from_now
      Billingly::Mailer.pending_notification(self).deliver!
      update_attribute(:notified_pending_on, Time.now)
    end

    def notify_overdue
      return unless notified_overdue_on.nil?
      return if paid?
      return if deleted?
      return if due_on > Time.now
      return if customer.do_not_email?
      Billingly::Mailer.overdue_notification(self).deliver!
      update_attribute(:notified_overdue_on, Time.now)
    end

    def notify_paid
      return unless paid?
      return unless notified_paid_on.nil?
      return if deleted?
      return if customer.do_not_email?
      Billingly::Mailer.paid_notification(self).deliver!
      update_attribute(:notified_paid_on, Time.now)
    end

    def generate_code
      self.code = loop do
        random_token = SecureRandom.urlsafe_base64
        break random_token unless self.class.where(code: random_token).exists?
      end
    end
  end
end
