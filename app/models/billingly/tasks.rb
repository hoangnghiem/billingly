# The Tasks model has all the tasks that should be run periodically through rake.
# A special log is created for the tasks being run and the results are reported
# back to the website administrator.
class Billingly::Tasks
  # The date in which the tasks started running.
  # @!attribute started
  # @return [DateTime] 
  attr_accessor :started

  # The date in which the tasks ended
  # @!attribute ended
  # @return [DateTime] 
  attr_accessor :ended

  # A summary of all the tasks that were run and their overall results.
  # @!attribute summary
  # @return [String]
  attr_accessor :summary

  # A detailed description of errors that ocurred while running all the tasks.
  #
  # @!attribute extended
  # @return [File]
  attr_accessor :extended

  # Runs all of Billingly's periodic tasks and creates a report with the results at the end.
  def run_all
    self.started = Time.now

    generate_next_invoices
    charge_invoices
    deactivate_all_debtors
    deactivate_all_expired_trials
    notify_all_paid
    notify_all_pending
    notify_all_overdue
    notify_all_trial_expired
    notify_all_will_trial_expire

    self.ended = Time.now
    self.extended.close unless self.extended.nil?
    Billingly::Mailer.task_results(self).deliver
  end
  
  # Writes a line to the {#extended} section of this tasks results report.
  # @param text [String]
  def log_extended(text)
    if self.extended.nil?
      time = Time.now.utc.strftime("%Y%m%d%H%M%S")
      self.extended = File.open("#{Rails.root}/log/billingly_#{time}.log", 'w')
    end
    self.extended.write("#{text}\n\n")
  end

  def log_error(text)
    self.extended ||= ''
    self.extended += "#{text}\n"
  end

  # Writes a line to the {#summary} section of this task results report.
  # @param text [String]
  def log_summary(text)
    self.summary ||= ''
    self.summary += "#{text}\n"
  end
  
  # The batch runner is a helper function for running a method on each item of a
  # collection logging the results, without aborting excecution if calling the rest of the
  # items if any of them fails.
  # 
  # The method called on each item will not receive parameters and should return
  # a Truthy value if successfull, or raise an exception otherwise.
  # Returning nil means that there was nothing to be done on that item.
  #
  # The collection to be used should be returned by a block provided to this method.
  # Any problem fetching the collection will also be universally captured
  #
  # See {#generate_next_invoices} for an example use.
  #
  # @param task_name [String] the name to use for this task in the generated log.
  # @param method [Symbol] the method to call on each one of the given items.
  # @param collection_getter [Proc] a block which should return the collection to use.
  def batch_runner(task_name, method, &collection_getter)
    collection = begin
      collection_getter.call
    rescue Exception => e
      failure += 1
      log_error("#{task_name}:\nCollection getter failed\n#{e.message}\n\n#{e.backtrace}")
      return
    end

    success = 0
    failure = 0

    collection.each do |item|
      begin
        success += 1 if item.send(method)
      rescue Exception => e
        failure += 1
        log_error("#{task_name}:\n#{e.message}\n#{item.inspect}\n\n#{e.backtrace}")
      end
    end

    if failure == 0
      log_summary("Success: #{task_name}, #{success} OK.")
    else
      log_summary("Failure: #{task_name}, #{success} OK, #{failure} failed.")
    end
  end
  
  # Invoices for running subscriptions which are not trials are generated by this task.
  # See {Billingly::Subscription#generate_next_invoice} for more information about
  # how the next invoice for a subscription is created.
  def generate_next_invoices
    batch_runner('Generating Invoices', :generate_next_invoice) do
      Billingly::Subscription
        .where(is_trial_expiring_on: nil, unsubscribed_on: nil)
        .readonly(false)
    end
  end

  # Charges all invoices for which the customer has enough balance.
  # Oldest invoices are charged first, newer invoices should not be charged until
  # the oldest ones are paid.
  # See {Billingly::Invoice#charge Invoice#Charge} for more information on
  # how invoices are charged from the customer's balance.
  # @param collection [Array<Invoice>] The list of invoices to attempt charging.
  #   Defaults to all invoices in the system.
  def charge_invoices
    batch_runner('Charging pending invoices', :charge_pending_invoices) do
      Billingly::Customer
        .joins(:invoices)
        .where(billingly_invoices: {deleted_on: nil, paid_on: nil})
        .readonly(false)
    end
  end

  # Notifies invoices that have been charged successfully, sending a receipt.
  # See {Billingly::Invoice#notify_paid Invoice#notify_paid} for more information on
  # how receipts are sent for paid invoices.
  def notify_all_paid
    batch_runner('Notifying Paid Invoices', :notify_paid) do
      Billingly::Invoice
        .where('paid_on is not null')
        .where(deleted_on: nil, notified_paid_on: nil)
        .readonly(false)
    end
  end
  
  # Customers are notified about their pending invoices by this task.
  # See {Billingly::Invoice#notify_pending Invoice#notify_pending} for more info
  # on how pending invoices are notified.
  def notify_all_pending
    batch_runner('Notifying Pending Invoices', :notify_pending) do
      Billingly::Invoice
        .where(deleted_on: nil, paid_on: nil, notified_pending_on: nil)
        .readonly(false)
    end
  end

  # This task notifies customers when one of their invoices is overdue.
  # Overdue invoices go together with account deactivations so the email sent
  # by this task also includes the deactivation notice.
  #
  # This task does not perform the actual deactivation, {#deactivate_all_debtors} does.
  #
  # See {Billingly::Invoice#notify_overdue Invoice#notify_overdue} for more info
  # on how overdue invoices are notified.
  def notify_all_overdue
    batch_runner('Notifying Overdue Invoices', :notify_overdue) do
      Billingly::Invoice
        .where('due_on <= ?', Time.now)
        .where(deleted_on: nil, paid_on: nil, notified_overdue_on: nil)
        .readonly(false)
    end
  end

  # Customers are notified about their trial is expired by this task.
  # See {Billingly::Subscription#notify_trial_expired Subscription#notify_trial_expired} for more info
  # on how trial expired are notified.
  def notify_all_trial_expired
    batch_runner('Notifying Trial Expired', :notify_trial_expired) do
      Billingly::Subscription.joins(:customer).readonly(false)
        .where("#{Billingly::Customer.table_name}.deactivation_reason = ?", 'trial_expired')
    end
  end

  # Customers are notified about their trial is about to expire by this task.
  # See {Billingly::Customer#notify_trial_will_expire Customer#notify_trial_will_expire} for more info
  # on how will trial expire are notified.
  def notify_all_will_trial_expire
    batch_runner('Notifying Trial Will Expire', :notify_trial_will_expire) do
      Billingly::Subscription.joins(:customer).readonly(false)
        .where("#{Billingly::Customer.table_name}.deactivated_since IS NULL")
        .where("#{Billingly::Subscription.table_name}.is_trial_expiring_on IS NOT NULL")
        .where("DATE(#{Billingly::Subscription.table_name}.is_trial_expiring_on) = ?", Date.today + Billingly.trial_before_days)
    end
  end

  # This method will deactivate all customers who have overdue {Billingly::Invoice Invoices}.
  #
  # This only deactivates the debtor, it does not notify them via email.
  # Look at {#notify_all_overdue} to see the email notification customers receive.
  #
  # See {Billingly::Customer#deactivate_debtor Customer#deactivate_debtor} for more info
  # on how debtors are deactivated.
  def deactivate_all_debtors
    batch_runner('Deactivating Debtors', :deactivate_debtor) do
      Billingly::Customer.debtors.where(deactivated_since: nil).readonly(false)
    end
  end

  # Customers may be subscribed for a trial period, and they are supposed to re-subscribe
  # before their trial expires.
  #
  # When their trial expires and they have not yet subscribed to another plan, we
  # deactivate their account immediately. This method does not email them about the
  # expired trial.
  #
  # See {Billingly::Customer#deactivate_trial_expired Customer#deactivate_trial_expired}
  # for more info on how trials are deactivated.
  def deactivate_all_expired_trials
    batch_runner('Deactivating Expired Trials', :deactivate_trial_expired) do
      Billingly::Customer.joins(:subscriptions).readonly(false)
        .where("#{Billingly::Subscription.table_name}.is_trial_expiring_on < ?", Time.now)
        .where(billingly_subscriptions: {unsubscribed_on: nil})
    end
  end

end
