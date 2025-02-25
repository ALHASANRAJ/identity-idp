require 'rails_helper'

RSpec.describe Navigation do
  let(:user) { build(:user) }

  subject(:navigation) { Navigation.new(user: user, url_options: {}) }

  describe '#navigation_items' do
    describe 'personal key' do
      context 'for a user with a personal key' do
        let(:user) { build(:user, personal_key: 'abcdef') }

        it 'has a link to reset personal key' do
          nav_item = navigation.navigation_items.first.children.last
          expect(nav_item.title).to eq(I18n.t('account.navigation.reset_personal_key'))
        end
      end

      context 'for a user that does not have a personal key' do
        it 'does not link to reset personal key' do
          has_reset_personal_key = navigation.navigation_items.first.children.any? do |item|
            item.title == I18n.t('account.navigation.reset_personal_key')
          end

          expect(has_reset_personal_key).to eq(false)
        end
      end
    end
  end
end
