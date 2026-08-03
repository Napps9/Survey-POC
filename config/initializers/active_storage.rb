# Serve SVG inline instead of Rails' default (application/octet-stream +
# Content-Disposition: attachment). The default exists because raw SVG can
# carry scripts — browsers never sniff SVG in <img>, so under it every
# uploaded SVG logo/brand asset renders as a blank image while the upload
# itself "succeeds". Safe to relax here because SVG reaches storage only
# through SvgSanitizer.clean_document (OrganisationsController#update,
# OrganisationAssetsController#create), and the SanitizeStoredSvgBrandAssets
# migration scrubbed everything attached before this initializer existed.
Rails.application.config.active_storage.content_types_to_serve_as_binary -= [ "image/svg+xml" ]
Rails.application.config.active_storage.content_types_allowed_inline += [ "image/svg+xml" ]
