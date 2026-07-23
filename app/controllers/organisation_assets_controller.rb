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
      return redirect_to organisation_memberships_path(org), alert: "Choose at least one image to add."
    end
    if org.assets.attachments.size + files.size > Organisation::MAX_ASSETS
      return redirect_to organisation_memberships_path(org),
        alert: "That would exceed your #{Organisation::MAX_ASSETS}-asset limit — remove some first."
    end
    # Validate BEFORE attaching: attaching to a saved record persists
    # immediately, so a bad file would otherwise land in storage before the
    # model validation could reject it.
    if (bad = files.find { |f| !valid_asset?(f) })
      return redirect_to organisation_memberships_path(org),
        alert: "“#{bad.original_filename}” must be a PNG, JPEG, GIF, WebP or SVG under #{Organisation::ASSET_MAX_BYTES / 1.megabyte} MB."
    end

    org.assets.attach(files)
    redirect_to organisation_memberships_path(org),
      notice: "Added #{files.size} #{'asset'.pluralize(files.size)} to your brand library."
  rescue => e
    ErrorReporting.report("OrganisationAssetsController#create", e)
    redirect_to organisation_memberships_path(org), alert: "Couldn't add those assets — please try again."
  end

  # DELETE /organisations/:organisation_id/assets/:id
  def destroy
    org = current_organisation
    # Synchronous purge, like the logo remove — the blob is a small image and
    # the admin expects it gone when the page reloads.
    org.assets.attachments.find(params[:id]).purge
    redirect_to organisation_memberships_path(org), notice: "Asset removed from your brand library."
  rescue ActiveRecord::RecordNotFound
    redirect_to organisation_memberships_path(org), alert: "That asset no longer exists."
  end

  private

  def valid_asset?(file)
    file.respond_to?(:content_type) &&
      Organisation::ASSET_CONTENT_TYPES.include?(file.content_type) &&
      file.size <= Organisation::ASSET_MAX_BYTES
  end
end
