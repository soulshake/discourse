module Jobs
  class CleanUpUploads < Jobs::Scheduled
    every 1.hour

    def execute(args)
      return unless SiteSetting.clean_up_uploads?

      base_url = Discourse.store.internal? ? Discourse.store.relative_base_url : Discourse.store.absolute_base_url
      s3_hostname = URI.parse(base_url).hostname
      s3_cdn_hostname = URI.parse(SiteSetting.s3_cdn_url || "").hostname

      # Any URLs in site settings are fair game
      ignore_urls = [
        SiteSetting.logo_url,
        SiteSetting.logo_small_url,
        SiteSetting.favicon_url,
        SiteSetting.apple_touch_icon_url,
      ].map do |url|
        url = url.dup
        url.gsub!(s3_cdn_hostname, s3_hostname) if s3_cdn_hostname.present?
        url[base_url] && url[url.index(base_url)..-1]
      end.compact.uniq

      grace_period = [SiteSetting.clean_orphan_uploads_grace_period_hours, 1].max

      result = Upload.where("uploads.retain_hours IS NULL OR uploads.created_at < current_timestamp - interval '1 hour' * uploads.retain_hours")
        .where("uploads.created_at < ?", grace_period.hour.ago)
        .joins("LEFT JOIN post_uploads pu ON pu.upload_id = uploads.id")
        .joins("LEFT JOIN users u ON u.uploaded_avatar_id = uploads.id")
        .joins("LEFT JOIN user_avatars ua ON (ua.gravatar_upload_id = uploads.id OR ua.custom_upload_id = uploads.id)")
        .joins("LEFT JOIN user_profiles up ON up.profile_background = uploads.url OR up.card_background = uploads.url")
        .joins("LEFT JOIN categories c ON c.uploaded_logo_id = uploads.id OR c.uploaded_background_id = uploads.id")
        .joins("LEFT JOIN custom_emojis ce ON ce.upload_id = uploads.id")
        .joins("LEFT JOIN theme_fields tf ON tf.upload_id = uploads.id")
        .where("pu.upload_id IS NULL")
        .where("u.uploaded_avatar_id IS NULL")
        .where("ua.gravatar_upload_id IS NULL AND ua.custom_upload_id IS NULL")
        .where("up.profile_background IS NULL AND up.card_background IS NULL")
        .where("c.uploaded_logo_id IS NULL AND c.uploaded_background_id IS NULL")
        .where("ce.upload_id IS NULL AND tf.upload_id IS NULL")

      result = result.where("uploads.url NOT IN (?)", ignore_urls) if ignore_urls.present?

      result.find_each do |upload|
        next if QueuedPost.where("raw LIKE '%#{upload.sha1}%'").exists?
        next if Draft.where("data LIKE '%#{upload.sha1}%'").exists?
        upload.destroy
      end
    end
  end
end
