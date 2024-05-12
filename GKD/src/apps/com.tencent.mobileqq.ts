import { defineGkdApp } from '@gkd-kit/define';

export default defineGkdApp({
  id: 'com.tencent.mobileqq',
  name: 'QQ (NT版本)',
  groups: [
    {
      key: 1,
      name: '其他广告-好友动态-好友热播',
      activityIds: [
        'com.qzone.reborn.feedx.activity.QZoneFriendFeedXActivity',
        'com.tencent.mobileqq.activity.SplashActivity',
      ],
      rules: [
        {
          key: 1,
          name: '点击右上角 [更多]',
          matches: [
            'LinearLayout > TextView[text="好友热播"] + Button[clickable=true]',
          ],
        },
        {
          key: 2,
          name: '点击 [减少好友热播]',
          preKeys: [1],
          matches: ['@[clickable=true] >2 [text="减少好友热播"]'],
        },
      ],
    },
    {
      key: 2,
      name: '其他广告-好友动态-为你推荐',
      enable: false,
      quickFind: true,
      activityIds: [
        'com.tencent.mobileqq.activity.SplashActivity',
        'com.qzone.reborn.feedx.activity.QZoneFriendFeedXActivity',
      ],
      rules: [
        {
          key: 1,
          name: '点击右上角 [更多]',
          matches: '@ImageView[clickable=true] - [text="为你推荐"]',
        },
        {
          key: 2,
          name: '点击 [减少此类推荐]',
          preKeys: 1,
          matches: [
            '@LinearLayout[id!=null][clickable=true] > LinearLayout > [text="减少此类推荐"]',
          ],
        },
      ],
    },
    {
      key: 3,
      name: '其他广告-消息列表顶部',
      activityIds: ['com.tencent.mobileqq.activity.SplashActivity'],
      rules: [
        {
          key: 1,
          name: '顶部卡片广告',
          matches: [
            'RelativeLayout[visibleToUser=true] > ImageView[clickable=true] +n RelativeLayout[childCount=2] > ImageView[childCount=0][visibleToUser=true][vid!="pic"][desc="关闭"||desc=null]',
          ],
        },
        {
          key: 2,
          name: '顶部更新提示',
          matches: [
            'LinearLayout > TextView[text="发现QQ版本更新"] + TextView[text="点击下载"] + ImageView',
          ],
        },
      ],
    },
    {
      key: 4,
      name: '功能优化-图片自动勾选原图',
      desc: '聊天发送图片自动勾选原图',
      enable: false,
      activityIds: ['com.tencent.mobileqq.activity.SplashActivity'],
      rules: [
        {
          key: 1,
          quickFind: true,
          matches: [
            'LinearLayout[vid="jst"] > TextView[vid="p2"][text="相册"] + TextView[vid="ekt"][text="编辑"] + CheckBox[vid="h1y"][checked=false][desc="原图"]',
          ],
        },
      ],
    },
    {
      key: 5,
      name: '更新提示-QQ更新提示',
      enable: false,
      quickFind: true,
      matchTime: 10000,
      actionMaximum: 1,
      resetMatch: 'app',
      actionMaximumKey: 0,
      rules: [
        {
          key: 0,
          matches: '@[desc="关闭"] - * > [text="发现新版本"]',
        },
        {
          key: 1,
          matches: '@[text="稍后处理"] +2 [text="立即升级"]',
        },
        {
          key: 3,
          matches: '@[desc="关闭"] - * > [text="QQ测试版"]',
        },
      ],
    },
  ],
});
