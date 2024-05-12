import { defineGkdApp } from '@gkd-kit/define';

export default defineGkdApp({
  id: 'com.coolapk.market',
  name: '酷安',
  groups: [
    {
      key: 1,
      name: '全屏广告-引流',
      rules: [
        {
          key: 0,
          name: '点击跳过',
          matches: [
            'FrameLayout[vid="bottom_container"] ImageView[vid="logo_view"]',
            'FrameLayout[vid="ad_container"] View[clickable=true][depth=13]',
          ],
        },
      ],
    },
    {
      key: 2,
      name: '其他广告-评论区-关闭广告',
      quickFind: true,
      activityIds: [
        'com.coolapk.market.view.main.MainActivity',
        'com.coolapk.market.view.base.SimpleAlphaActivity',
        'com.coolapk.market.view.node.DynamicNodePageActivity',
        'com.coolapk.market.view.feed.FeedDetailActivityV8',
      ],
      rules: [
        {
          key: 0,
          name: '点击关闭按钮',
          matches: [
            'FrameLayout[id="com.coolapk.market:id/coolapk_card_view"] TextView[vid="title_view"][text*="广告"]',
            'FrameLayout[id="com.coolapk.market:id/coolapk_card_view"] ImageView[vid="close_view"][desc="关闭"]',
          ],
        },
        {
          key: 1,
          name: '点击关闭广告',
          preKeys: [0],
          matches: [
            'TextView[id="com.coolapk.market:id/alertTitle"][text="关闭广告"]',
            'Button[id="android:id/button3"][text*="今日免广告"]',
            'Button[id="android:id/button1"][text="关闭"]',
          ],
        },
      ],
    },
    {
      key: 3,
      name: '其他广告-信息流-关闭广告',
      quickFind: true,
      activityIds: [
        'com.coolapk.market.view.main.MainActivity',
        'com.coolapk.market.view.base.SimpleAlphaActivity',
        'com.coolapk.market.view.node.DynamicNodePageActivity',
        'com.coolapk.market.view.feed.FeedDetailActivityV8',
      ],
      rules: [
        {
          key: 0,
          name: '点击关闭按钮',
          matches: [
            'CardView[id="com.coolapk.market:id/coolapk_card_view"] TextView[vid="ad_time_view"][text="来自广告推荐"]',
            'CardView[id="com.coolapk.market:id/coolapk_card_view"] ImageView[vid="close_view"][desc="关闭"]',
          ],
        },
        {
          key: 1,
          name: '点击关闭广告',
          preKeys: [0],
          matches: [
            'TextView[id="com.coolapk.market:id/alertTitle"][text="关闭广告"]',
            'Button[id="android:id/button3"][text*="今日免广告"]',
            'Button[id="android:id/button1"][text="关闭"]',
          ],
        },
      ],
    },
    {
      key: 4,
      name: '功能优化-自动查看原图',
      desc: '查看图片时自动点击原图',
      enable: false,
      quickFind: true,
      activityIds: 'com.coolapk.market.view.photo.PhotoViewActivity',
      rules: '[vid="load_source_button"][text="原图"]',
    },
  ],
});
