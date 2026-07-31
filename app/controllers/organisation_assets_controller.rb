# The account's own brand-asset library. Admins upload images here (from the
# branding page) and they become pickable in every Verto's media picker,
# scoped to this organisation only — the per-account counterpart of the shared
# Verto Library. Attachments live on Organisation#assets (Active Storage).
class OrganisationAssetsController < ApplicationController
  layout "fullscreen"
  before_action :require_admin!

  # POST /organisations/:organisation_id/assets
  def create
    org   = current_organisation
    files = Array(params[:assets]).reject(&:blank?)

    if files.empty?
      return redirect_to organisation_memberships_path(org), alert: t("flash.organisation_assets.no_files_chosen")
    end
    if org.assets.attachments.size + files.size > Organisation::MAX_ASSETS
      return redirect_to organisation_memberships_path(org),
        alert: t("flash.organisation_assets.asset_limit_exceeded", limit: Organisation::MAX_ASSETS)
    end
    # Validate BEFORE attaching: attaching to a saved record persists
    # immediately, so a bad file would otherwise land in storage before the
    # model validation could reject it.
    if (bad = files.find { |f| !valid_asset?(f) })
      return redirect_to organisation_memberships_path(org),
        alert: t("flash.organisation_assets.invalid_asset_file", filename: bad.original_filename, size: Organisation::ASSET_MAX_BYTES / 1.megabyte)
    end

    org.assets.attach(files)
    redirect_to organisation_memberships_path(org),
      notice: t("flash.organisation_assets.assets_added", count: files.size)
  rescue => e
    ErrorReporting.report("OrganisationAssetsController#create", e)
    redirect_to organisation_memberships_path(org), alert: t("flash.organisation_assets.add_failed")
  end

  # DELETE /organisations/:organisation_id/assets/:id
  def destroy
    org = current_organisation
    # Synchronous purge, like the logo remove — the blob is a small image and
    # the admin expects it gone when the page reloads.
    org.assets.attachments.find(params[:id]).purge
    redirect_to organisation_memberships_path(org), notice: t("flash.organisation_assets.asset_removed")
  rescue ActiveRecord::RecordNotFound
    redirect_to organisation_memberships_path(org), alert: t("flash.organisation_assets.asset_missing")
  end

  private

  def valid_asset?(file)
    file.respond_to?(:content_type) &&
      Organisation::ASSET_CONTENT_TYPES.include?(file.content_type) &&
      file.size <= Organisation::ASSET_MAX_BYTES
  end
end
