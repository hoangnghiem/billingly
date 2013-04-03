# People who have a {Billingly::SpecialPlanCode SpecialPlanCode} can redeem it through
# the {Billingly::RedemptionsController}
class Billingly::RedemptionsControllerBase < Billingly::BaseController
  def new
  end
  
  def create
    code = Billingly::SpecialPlanCode.find_redeemable(params[:promo_code])
    if code.nil?
      flash[:invalid_promo_code] = t('billingly.promo_codes.invalid')
      redirect_to new_redemption_path
      return
    end

    unless current_customer
      session[:current_promo_code] = params[:promo_code] 
      on_redemption_by_non_customer
      return
    end

    unless current_customer.can_subscribe_to?(code.plan)
      flash[:invalid_promo_code_plan] = t('billingly.promo_codes.cannot_subscribe_to_plan')
      redirect_to new_redemption_path
      return
    end

    current_customer.redeem_special_plan_code(code)
    on_redemption
  end
  
  # When a code is redeemed successfully by the current customer this callback is called.
  # The default behavior is redirecting to the subscriptions index page.
  def on_redemption
    redirect_to subscriptions_path, notice: t('billingly.promo_codes.redeemed_successfully')
  end
  
  # The redemptions page is public, therefore there may be people redeeming valid codes
  # without being a customer.
  #
  # In such cases, the validated code is stored in the session and this callback is called.
  # You should redirect to your signup page here, and subscribe the customer using the saved
  # code after they sign up.
  # The code and plan associated to this code can be retrieved using {#current_promo_code}
  # and {#current_promo_code_plan}
  def on_redemption_by_non_customer
  end
end
