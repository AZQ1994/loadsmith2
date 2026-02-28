#!/usr/bin/env ruby
# frozen_string_literal: true

# Loadsmith2 サンプル — ソシャゲ負荷テスト
#
# 起動方法:
#   1. ruby bin/test_server
#   2. ruby example/sample_test.rb

require_relative "../lib/loadsmith"

# ─── 設定 ───────────────────────────────────────────

Loadsmith.config do
  self.base_url     = "http://localhost:8080"
  self.workers      = 4
  self.users        = 50
  self.spawn_rate   = 10
  self.open_timeout = 5
  self.read_timeout = 15
end

# ─── 画面定義 ───────────────────────────────────────

Loadsmith.screen :home do |ctx|
  ctx.get "/api/home"
  ctx.get "/api/home/notifications"
end

Loadsmith.screen :card_list do |ctx|
  res = ctx.get "/api/cards"
  if res
    data = JSON.parse(res.body)
    ctx.store[:cards] = data["cards"]
  end
end

Loadsmith.screen :card_detail do |ctx|
  card = ctx.store[:cards]&.sample
  if card
    ctx.get "/api/cards/detail?id=#{card['id']}", name: "/api/cards/detail"
    ctx.store[:current_card] = card
  end
end

Loadsmith.screen :card_enhance do |ctx|
  card = ctx.store[:current_card]
  if card
    ctx.post "/api/cards/enhance", json: {
      card_id: card["id"],
      current_level: card["level"]
    }
  end
end

Loadsmith.screen :gacha_top do |ctx|
  res = ctx.get "/api/gacha/lineup"
  if res
    data = JSON.parse(res.body)
    ctx.store[:gacha_banners] = data["banners"]
  end
end

Loadsmith.screen :gacha_draw do |ctx|
  banner = ctx.store[:gacha_banners]&.first
  if banner
    ctx.post "/api/gacha/draw", json: {
      banner_id: banner["id"],
      count: [1, 10].sample
    }
  end
end

Loadsmith.screen :missions do |ctx|
  res = ctx.get "/api/missions"
  if res
    data = JSON.parse(res.body)
    completed = data["daily"]&.select { _1["completed"] && !_1["claimed"] }
    ctx.store[:claimable_missions] = completed || []
  end
end

Loadsmith.screen :mission_claim do |ctx|
  mission = ctx.store[:claimable_missions]&.first
  if mission
    ctx.post "/api/missions/claim", json: { mission_id: mission["id"] }
  end
end

Loadsmith.screen :shop do |ctx|
  ctx.get "/api/shop"
end

Loadsmith.screen :shop_buy do |ctx|
  ctx.post "/api/shop/buy", json: { item_id: 1, quantity: 1 }
end

# ─── サブシナリオ（画面遷移フロー） ─────────────────

# カード画面：一覧 → 詳細 → たまに強化
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
      # 眺めるだけ
    end
  end
end

# ガチャフロー：ラインナップ確認 → 引く
Loadsmith.scenario :gacha_flow do
  visit :gacha_top
  think 1..3
  visit :gacha_draw
end

# ミッションフロー：確認 → 報酬受取
Loadsmith.scenario :mission_flow do
  visit :missions
  think 0.5..1
  visit :mission_claim
end

# ショップフロー：閲覧 → たまに購入
Loadsmith.scenario :shop_flow do
  visit :shop
  think 1..2

  choose do
    percent 30 do
      visit :shop_buy
    end
    percent 70 do
      # ウィンドウショッピング
    end
  end
end

# ─── メインシナリオ ─────────────────────────────────

Loadsmith.scenario :main do
  visit :home
  think 1..3

  # ユーザーは各コンテンツにランダムに遷移する
  choose do
    percent 40, scenario: :card_flow
    percent 25, scenario: :gacha_flow
    percent 20, scenario: :mission_flow
    percent 15, scenario: :shop_flow
  end
end

# ─── ライフサイクル ─────────────────────────────────

Loadsmith.on_start do |ctx|
  res = ctx.post "/api/auth/login", json: { user_id: "user_#{ctx.user_id}" }
  if res
    data = JSON.parse(res.body)
    ctx.default_headers["Authorization"] = "Bearer #{data['token']}"
  end
end

Loadsmith.on_stop do |ctx|
  ctx.post "/api/auth/logout"
end

# ─── 実行 ───────────────────────────────────────────

Loadsmith.run :main
