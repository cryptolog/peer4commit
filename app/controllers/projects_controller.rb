require 'net/http'

class ProjectsController < ApplicationController

  before_action :load_project, only: [:qrcode, :edit, :update, :decide_tip_amounts]

  def index
    @projects = Project.enabled.order(available_amount_cache: :desc, watchers_count: :desc, full_name: :asc).page(params[:page]).per(30)
  end

  def show
    @project = Project.where(id: params[:id]).first
    unless @project
      redirect_to root_path, alert: "Project not found"
      return
    end
    if @project.bitcoin_address.nil? and (github_id = @project.github_id).present?
      label = "#{github_id}@peer4commit"
      address = BitcoinDaemon.instance.get_new_address(label)
      @project.update_attributes(bitcoin_address: address, address_label: label)
    end
  end

  def edit
    authorize! :update, @project
  end

  def update
    authorize! :update, @project
    @project.attributes = project_params
    if @project.tipping_policies_text.try(:text_changed?)
      @project.tipping_policies_text.user = current_user
    end
    if @project.save
      redirect_to project_path(@project), notice: "The project settings have been updated"
    else
      render 'edit'
    end
  end

  def decide_tip_amounts
    authorize! :decide_tip_amounts, @project
    if request.patch?
      @project.attributes = params.require(:project).permit(tips_attributes: [:id, :decided_amount_percentage, :decided_free_amount])
      @project.tips.each do |tip|
        next if tip.decided?
        if tip.decided_amount_percentage.present?
          tip.amount = @project.available_amount * (tip.decided_amount_percentage.to_f / 100)
        elsif tip.decided_free_amount.present?
          tip.amount = tip.decided_free_amount.to_d * COIN
        end
      end
      if @project.available_amount < 0
        flash.now[:error] = "The project has insufficient funds"
        return
      end
      if @project.save
        message = "The tip amounts have been defined"
        if @project.has_undecided_tips?
          redirect_to decide_tip_amounts_project_path(@project), notice: message
        else
          redirect_to @project, notice: message
        end
      end
    end
  end

  def qrcode
    respond_to do |format|
      format.svg  { render qrcode: @project.bitcoin_address, level: :l, unit: 4 }
    end
  end

  def create
    project_name = params[:full_name].
      gsub(/https?\:\/\/github.com\//, '').
      gsub(/\#.+$/, '').
      gsub(' ', '')
    client = Octokit::Client.new \
      :client_id     => CONFIG['github']['key'],
      :client_secret => CONFIG['github']['secret']
    begin
      repo = client.repo project_name
      @project = Project.find_or_create_by full_name: repo.full_name
      @project.update_github_info repo
      redirect_to @project
    rescue Octokit::NotFound
      redirect_to projects_path, alert: "Project not found"
    end
  end

  private
  def project_params
    params.require(:project).permit(:hold_tips, tipping_policies_text_attributes: [:text])
  end

  def load_project
    @project = Project.enabled.where(id: params[:id]).first
    unless @project
      redirect_to root_path, alert: "Project not found"
    end
  end
end
