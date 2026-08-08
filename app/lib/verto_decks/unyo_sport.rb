module VertoDecks
  # The deck VertoCsvImporter was originally written for, and still its default.
  #
  # Its questions and option lists stay where they were — as constants and
  # builders on VertoCsvImporter — because the existing tests reach for them by
  # name (VertoCsvImporter::SKILLS, ::GENDER_OPTS, ::HOPEFUL…) and moving them
  # would be churn for its own sake. What this class adds is only the identity
  # and wording the importer used to hardcode, so a SECOND deck has somewhere to
  # put its own without editing the import path.
  class UnyoSport < Base
    def org_name    = "UNYO"
    def org_slug    = "unyo"
    def admin_email = "admin@unyo.example"
    def title       = "UNYO Sport x Changemaking 2026"
    def verto_slug  = "unyo-sport-changemaking"

    def brand_palette
      { "primary" => "#00C2A8", "cta" => "#FF5A5F", "bg" => "#0F1B2D" }
    end

    def survey_attributes
      {
        theme: "sport, wellbeing and changemaking",
        audience_age: "youth",
        key_insight: "How young people experience sport — activity, wellbeing, skills, access and voice.",
        show_results_comparison: true,
        compare_note: "See how your answers compare with everyone else who took part."
      }
    end

    def specs(importer) = importer.send(:unyo_specs)
  end
end
