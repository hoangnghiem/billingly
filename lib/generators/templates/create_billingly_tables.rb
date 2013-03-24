class CreateBillinglyTables < ActiveRecord::Migration
  def change
    create_table :billingly_customers do |t|
      t.datetime 'deactivated_since'
      t.string 'deactivation_reason'
      t.string 'email', null: false
    end
    
    create_table :billingly_invoices do |t|
      t.string 'code'
      t.references :customer, null: false
      t.references :subscription
      t.decimal 'amount', precision: 11, scale: 2, default: 0.0, null: false
      t.datetime 'paid_on'
      t.datetime 'due_on', null: false
      t.datetime 'period_start', null: false
      t.datetime 'period_end', null: false
      t.datetime 'deleted_on'
      t.datetime 'notified_pending_on'
      t.datetime 'notified_overdue_on'
      t.datetime 'notified_paid_on'
      t.text 'comment'
      t.timestamps
    end

    create_table :billingly_payments do |t|
      t.references :customer, null: false
      t.decimal 'amount', precision: 11, scale: 2, default: 0.0, null: false
    end
    
    create_table :billingly_journal_entries do |t|
      t.references :customer, null: false
      t.string :account, null: false
      t.decimal 'amount', precision: 11, scale: 2, default: 0.0, null: false
      t.references :subscription
      t.references :invoice
      t.references :payment
      t.timestamps
    end
    
    create_table :billingly_subscriptions do |t|
      t.references :customer, null: false
      t.string 'description', null: false
      t.datetime 'subscribed_on', null: false
      t.string 'periodicity', null: false
      t.string 'grace_period', null: false
      t.boolean 'payable_upfront', null: false, default: false
      t.decimal 'amount', precision: 11, scale: 2, default: 0.0, null: false
      t.datetime 'unsubscribed_on'
      t.string 'unsubscribed_because'
      t.datetime 'is_trial_expiring_on'
      t.datetime 'notified_trial_will_expire_on'
      t.datetime 'notified_trial_expired_on'
      t.references :plan
      t.decimal :signup_price, precision: 11, scale: 2
      t.timestamps
    end
    
    create_table :billingly_plans do |t|
      t.string 'name' # Pro 50
      t.string 'description' # 50GB for 9,99 a month.
      t.string 'periodicity'
      t.decimal 'amount', precision: 11, scale: 2, default: 0.0, null: false # 9.99
      t.boolean 'payable_upfront', null: false
      t.string 'grace_period', null: false
      t.integer 'signup_price'
      t.boolean 'hidden', default: false, null: false
      t.timestamps
    end
    
    create_table :billingly_special_plan_codes do |t|
      t.references :plan, null: false
      t.decimal :bonus_amount, precision: 11, scale: 2
      t.string :code
      t.references :customer
      t.datetime :redeemed_on
      t.timestamps
    end
    add_index :billingly_special_plan_codes, :code, :unique => true
  end
end

