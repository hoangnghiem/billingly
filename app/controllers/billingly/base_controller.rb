class Billingly::BaseController < Billingly.parent_controller.constantize

  def current_customer
    nil
  end

  def requires_customer
    on_empty_customer if current_customer.nil? 
  end

  # This method is call on a before filter when a customer was required
  # but none was found. It's reccommended that this method redirects to
  # a login url or out of the site.
  def on_empty_customer
    redirect_to(root_path)
  end
  
  # This before filter should apply to all actions that require an active
  # customer. Usually this would mean all your non-public pages.
  # The billingly controllers already apply this before filter, you should
  # use it in your own controllers too.
  def requires_active_customer
    if requires_customer.nil? && current_customer.deactivated?
      redirect_to(subscriptions_path)
    end
  end
  
  # When an anonymous user redeems a {SpecialPlanCode} the code is stored
  # in the session. You should first sign them up and then subscribe them
  # using the code they previously redeemed.
  # @return [SpecialPlanCode] The instance for the code they redeemed.
  def current_promo_code
    @current_promo_code ||=
      Billingly::SpecialPlanCode.find_redeemable(session[:current_promo_code])
  end
  
  # Shortcut for getting the plan for the current promo code, if any.
  # @return [Billingly::Plan] The plan referred to by the current code.
  def current_promo_code_plan
    @current_promo_code.plan if @current_promo_code
  end

  helper_method :current_customer, :current_promo_code, :current_promo_code_plan
  
end