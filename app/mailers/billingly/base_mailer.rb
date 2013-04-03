class Billingly::BaseMailer < ActionMailer::Base
  # default from: 'example@example.com'
  
  cattr_accessor :admin_emails
  self.admin_emails = 'admin@example.com'

  def pending_notification(invoice)
    @invoice = invoice
    @cash = invoice.customer.ledger[:cash]
    mail(to: invoice.customer.email, subject: I18n.t('billingly.your_invoice_is_available'))
  end
  
  def overdue_notification(invoice)
    @invoice = invoice
    @cash = invoice.customer.ledger[:cash]
    mail(to: invoice.customer.email, subject: I18n.t('billingly.your_account_was_suspended'))
  end
  
  def paid_notification(invoice)
    @invoice = invoice
    mail(to: invoice.customer.email, subject: I18n.t('billingly.payment_receipt'))
  end
  
  def task_results(runner)
    @runner = runner
    mail to: self.class.admin_emails, subject: "Your Billingly Status Report"
  end
  
  # Sends the email about an expired trial.
  # param trial [Subscription] a trial which should be expired.
  def trial_expired_notification(subscription)
    @subscription = subscription
    mail to: subscription.customer.email, subject: I18n.t('billingly.your_trial_has_expired')
  end

  # Sends the email about an expired trial.
  # param trial [Subscription] a trial which should be expired.
  def trial_will_expire_notification(subscription)
    @subscription = subscription
    mail to: subscription.customer.email, subject: I18n.t('billingly.your_trial_will_expire', day: Billingly.trial_before_days)
  end
end
