class AddEnumCheckConstraints < ActiveRecord::Migration[8.1]
  # P2-8. Every one of these columns already has a Rails enum or an inclusion
  # validation, which holds only for writes that go through Active Record. A
  # console session, an import script or a future bulk update can put any
  # string in them, and the failure is silent: an unknown `status` just never
  # matches a scope, so rows quietly vanish from counts rather than erroring.
  #
  # Values are taken from the model that owns each column, so the database and
  # the model can't drift apart without one of them failing loudly.
  #
  # Deploy note: a CHECK constraint is validated against existing rows when it
  # is added, so a stray value anywhere makes this migration fail. That is the
  # intended outcome rather than a hazard — render.yaml runs migrations in
  # preDeployCommand, so a failure blocks the deploy and the running instance
  # keeps serving. Better to find out there than to discover it later.
  CONSTRAINTS = {
    funders:                 [ :status, %w[active revoked] ],
    funder_memberships:      [ :status, %w[active suspended] ],
    invites:                 [ :kind,   %w[member partner licensee] ],
    memberships:             [ :role,   %w[member admin] ],
    partnerships:            [ :status, %w[active pending revoked] ],
    partnership_memberships: [ :status, %w[active pending revoked] ],
    flow_generations:        [ :status, %w[pending running succeeded failed] ],
    report_renders:          [ :status, %w[pending running succeeded failed] ],
    verto_builds:            [ :status, %w[pending running succeeded failed] ],
    responses:               [ :status, %w[started completed] ]
  }.freeze

  # verto_builds.kind is the one column with two constrained fields on one table.
  EXTRA = { verto_builds: [ :kind, %w[generate import_manual import_google_form import_pdf] ] }.freeze

  def up
    (CONSTRAINTS.to_a + EXTRA.to_a).each do |table, (column, allowed)|
      add_check_constraint table, sql_for(column, allowed), name: "chk_#{table}_#{column}"
    end
  end

  def down
    (CONSTRAINTS.to_a + EXTRA.to_a).each do |table, (column, _allowed)|
      remove_check_constraint table, name: "chk_#{table}_#{column}"
    end
  end

  private

  def sql_for(column, allowed)
    list = allowed.map { |v| "'#{v}'" }.join(", ")
    "#{column} IN (#{list})"
  end
end
