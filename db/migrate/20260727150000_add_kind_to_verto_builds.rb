class AddKindToVertoBuilds < ActiveRecord::Migration[8.1]
  # The wizard's other three doors — pasted questions, a Google Form and an
  # uploaded PDF — run the same shape of slow AI call that generation does, so
  # they share the build record rather than growing three near-identical ones.
  #
  # The imports differ in one way that matters: they don't always end at a
  # Verto. Questions that break the design rules pause at a review screen where
  # the creator picks their own wording or Verto's, so a finished import build
  # hands back to the request to make that call.
  def change
    add_column :verto_builds, :kind, :string, null: false, default: "generate"
  end
end
