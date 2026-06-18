require "test_helper"

# Guards the member-invite accept flow against account takeover: an invite link
# whose email matches an *existing* account must not sign the visitor in as that
# account unless they prove ownership (correct password, or already signed in).
class InviteMemberAcceptTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(name: "Admin", email_address: "admin-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org   = Organisation.create!(name: "Host Co", slug: "host-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @admin, role: "admin")
  end

  def member_invite_for(email)
    @org.invites.create!(
      email_address: email, role: "member", kind: "member",
      invited_by: @admin, expires_at: 7.days.from_now
    )
  end

  test "accepting a member invite for an existing account WITHOUT its password is rejected" do
    victim = User.create!(name: "Victim", email_address: "victim-#{SecureRandom.hex(2)}@test.com", password: "victimspassword12")
    invite = member_invite_for(victim.email_address)

    post accept_invite_path(invite.token), params: {
      name: "Attacker", password: "attackerschoice12", password_confirmation: "attackerschoice12"
    }

    assert_response :unprocessable_entity
    assert_match "Enter its password", response.body
    refute @org.memberships.exists?(user: victim), "victim must not be added to the org"
    refute invite.reload.accepted?, "invite must not be consumed"

    # And no session was established as the victim.
    get root_path
    assert_redirected_to new_session_path
  end

  test "accepting a member invite for an existing account WITH its password joins and signs in" do
    user   = User.create!(name: "Returning", email_address: "ret-#{SecureRandom.hex(2)}@test.com", password: "theirrealpassword1")
    invite = member_invite_for(user.email_address)

    post accept_invite_path(invite.token), params: {
      name: "Returning", password: "theirrealpassword1", password_confirmation: "theirrealpassword1"
    }

    assert_redirected_to root_path
    assert @org.memberships.exists?(user: user), "owner with the right password joins"
    assert invite.reload.accepted?

    get root_path
    assert_response :success, "should be signed in as the existing user"
  end

  test "a brand-new invitee can accept and gets an account" do
    email  = "newbie-#{SecureRandom.hex(2)}@test.com"
    invite = member_invite_for(email)

    assert_difference -> { User.count }, 1 do
      post accept_invite_path(invite.token), params: {
        name: "Newbie", password: "abrandnewpassword1", password_confirmation: "abrandnewpassword1"
      }
    end

    assert_redirected_to root_path
    user = User.find_by(email_address: email)
    assert @org.memberships.exists?(user: user)
    assert invite.reload.accepted?
  end

  test "an existing user already signed in as themselves can accept without re-entering a password" do
    user   = User.create!(name: "Self", email_address: "self-#{SecureRandom.hex(2)}@test.com", password: "myownpassword1234")
    invite = member_invite_for(user.email_address)

    post session_path, params: { email_address: user.email_address, password: "myownpassword1234" }
    follow_redirect!

    post accept_invite_path(invite.token), params: { name: "Self" }

    assert_redirected_to root_path
    assert @org.memberships.exists?(user: user)
    assert invite.reload.accepted?
  end
end
