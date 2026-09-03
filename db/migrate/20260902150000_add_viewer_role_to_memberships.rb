class AddViewerRoleToMemberships < ActiveRecord::Migration[8.1]
  # A third membership role, "viewer" — shares Vertos and sees results, never
  # creates or edits. The CHECK constraint from AddEnumCheckConstraints pins
  # memberships.role to the model's enum values, so the list has to grow here
  # before Membership can write the new one.
  #
  # Values are spelled out rather than read from Membership::ROLES on purpose:
  # a migration that reads the model would silently change meaning the next
  # time the model does, and this one records what the database allowed on
  # the day it ran.
  OLD_ROLES = %w[member admin].freeze
  NEW_ROLES = %w[viewer member admin].freeze

  def up
    remove_check_constraint :memberships, name: "chk_memberships_role"
    add_check_constraint    :memberships, sql_for(NEW_ROLES), name: "chk_memberships_role"
  end

  # Rolling back with viewer rows present fails on the constraint, which is
  # the right outcome: silently dropping those memberships (or promoting them
  # to member) is not something a schema rollback should decide.
  def down
    remove_check_constraint :memberships, name: "chk_memberships_role"
    add_check_constraint    :memberships, sql_for(OLD_ROLES), name: "chk_memberships_role"
  end

  private

  def sql_for(allowed)
    "role IN (#{allowed.map { |v| "'#{v}'" }.join(", ")})"
  end
end
