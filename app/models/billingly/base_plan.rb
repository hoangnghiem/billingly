module Billingly
  require 'has_duration'
  class BasePlan < ActiveRecord::Base
    self.abstract_class = true
    self.table_name = 'billingly_plans'

    attr_accessible :name, :plan_code, :description, :periodicity,
      :amount, :payable_upfront, :grace_period, :hidden
    
    has_duration :grace_period
    validates :grace_period, presence: true

    has_duration :periodicity
    validates :periodicity, presence: true
    
  end
end
