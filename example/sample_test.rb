#!/usr/bin/env ruby
# frozen_string_literal: true

# Loadsmith2 Sample — Mobile game load test
#
# Usage:
#   1. ruby bin/test_server
#   2. ruby example/sample_test.rb

require_relative "../lib/loadsmith"

# ─── Configuration ────────────────────────────────────

Loadsmith.config do
  self.base_url     = "http://localhost:8080"
  self.workers      = 4
  self.users        = 50
  self.spawn_rate   = 10
  self.open_timeout = 5
  self.read_timeout = 15
end

# ─── API Definitions (Access classes) ─────────────────

class Login < Loadsmith::Access
  post "/api/auth/login"

  def request_json
    { user_id: "user_#{ctx.user_id}" }
  end

  def after(res)
    ctx.default_headers["Authorization"] = "Bearer #{res['token']}" if res.success?
  end
end

class Logout < Loadsmith::Access
  post "/api/auth/logout"
end

class Home < Loadsmith::Access
  get "/api/home"
end

class HomeNotifications < Loadsmith::Access
  get "/api/home/notifications"
end

class CardList < Loadsmith::Access
  get "/api/cards"

  def after(res)
    ctx.store[:cards] = res["cards"] if res.success?
  end
end

class CardDetail < Loadsmith::Access
  get "/api/cards/detail"
  name "/api/cards/detail"

  def before
    @card = ctx.store[:cards]&.sample
    ctx.store[:current_card] = @card
  end

  def request_params
    @card ? { id: @card["id"] } : {}
  end
end

class CardEnhance < Loadsmith::Access
  post "/api/cards/enhance"

  def request_json
    card = ctx.store[:current_card]
    { card_id: card["id"], current_level: card["level"] }
  end
end

class GachaLineup < Loadsmith::Access
  get "/api/gacha/lineup"

  def after(res)
    ctx.store[:gacha_banners] = res["banners"] if res.success?
  end
end

class GachaDraw < Loadsmith::Access
  post "/api/gacha/draw"

  def request_json
    banner = ctx.store[:gacha_banners]&.first
    { banner_id: banner["id"], count: [1, 10].sample }
  end
end

class MissionList < Loadsmith::Access
  get "/api/missions"

  def after(res)
    if res.success?
      completed = res["daily"]&.select { _1["completed"] && !_1["claimed"] }
      ctx.store[:claimable_missions] = completed || []
    end
  end
end

class MissionClaim < Loadsmith::Access
  post "/api/missions/claim"

  def request_json
    mission = ctx.store[:claimable_missions]&.first
    { mission_id: mission["id"] }
  end
end

class ShopList < Loadsmith::Access
  get "/api/shop"
end

class ShopBuy < Loadsmith::Access
  post "/api/shop/buy"

  def request_json
    { item_id: 1, quantity: 1 }
  end
end

# ─── Screen Definitions ──────────────────────────────

Loadsmith.screen :home do |ctx|
  Home.call(ctx)
  HomeNotifications.call(ctx)
end

Loadsmith.screen :card_list do |ctx|
  CardList.call(ctx)
end

Loadsmith.screen :card_detail do |ctx|
  CardDetail.call(ctx) if ctx.store[:cards]&.any?
end

Loadsmith.screen :card_enhance do |ctx|
  CardEnhance.call(ctx) if ctx.store[:current_card]
end

Loadsmith.screen :gacha_top do |ctx|
  GachaLineup.call(ctx)
end

Loadsmith.screen :gacha_draw do |ctx|
  GachaDraw.call(ctx) if ctx.store[:gacha_banners]&.any?
end

Loadsmith.screen :missions do |ctx|
  MissionList.call(ctx)
end

Loadsmith.screen :mission_claim do |ctx|
  MissionClaim.call(ctx) if ctx.store[:claimable_missions]&.any?
end

Loadsmith.screen :shop do |ctx|
  ShopList.call(ctx)
end

Loadsmith.screen :shop_buy do |ctx|
  ShopBuy.call(ctx)
end

# ─── Sub-scenarios (screen transition flows) ─────────

# Card flow: list -> detail -> sometimes enhance
Loadsmith.scenario :card_flow do
  visit :card_list
  think 1..2
  visit :card_detail
  think 0.5..1

  choose do
    percent 40 do
      visit :card_enhance
    end
    percent 60 do
      # just browsing
    end
  end
end

# Gacha flow: check lineup -> draw
Loadsmith.scenario :gacha_flow do
  visit :gacha_top
  think 1..3
  visit :gacha_draw
end

# Mission flow: check -> claim rewards
Loadsmith.scenario :mission_flow do
  visit :missions
  think 0.5..1
  visit :mission_claim
end

# Shop flow: browse -> sometimes buy
Loadsmith.scenario :shop_flow do
  visit :shop
  think 1..2

  choose do
    percent 30 do
      visit :shop_buy
    end
    percent 70 do
      # window shopping
    end
  end
end

# ─── Main Scenario ───────────────────────────────────

Loadsmith.scenario :main do
  visit :home
  think 1..3

  # Users navigate to random content
  choose do
    percent 40, scenario: :card_flow
    percent 25, scenario: :gacha_flow
    percent 20, scenario: :mission_flow
    percent 15, scenario: :shop_flow
  end
end

# ─── Lifecycle ───────────────────────────────────────

Loadsmith.on_start do |ctx|
  Login.call(ctx)
end

Loadsmith.on_stop do |ctx|
  Logout.call(ctx)
end

# ─── Run ─────────────────────────────────────────────

if ARGV.include?("--web")
  Loadsmith.serve(port: 8089)
else
  Loadsmith.run :main
end
