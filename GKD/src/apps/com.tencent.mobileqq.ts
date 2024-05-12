import { defineGkdApp } from '@gkd-kit/define';

export default defineGkdApp({
  id: 'com.tencent.mobileqq',
  name: 'QQ (NT版本)',
  groups: [
    {
      key: 1,
      name: '更新提示-隐藏更新提示',
      desc: '叉掉顶部更新提示',
      activityIds: ['com.tencent.mobileqq.activity.SplashActivity'],
      rules: [
        {
          key: 1,
          name: '点击取消按钮',
          matches: [
            'LinearLayout > TextView[text="发现QQ版本更新"] + TextView[text="点击下载"] + ImageView',
          ],
        },
      ],
    },
    {
      key: 2,
      name: '其他广告-好友动态-好友热播',
      activityIds: ['com.qzone.reborn.feedx.activity.QZoneFriendFeedXActivity'],
      rules: [
        {
          key: 1,
          name: '点击更多',
          matches: [
            'LinearLayout > TextView[vid="k2r"][text="好友热播"] + Button[vid="jvj"]',
          ],
        },
        {
          key: 2,
          name: '点击更多后-不感兴趣',
          preKeys: [1],
          matches: [
            'LinearLayout[vid="h0f"] TextView[vid="hhb"][text="不感兴趣"]',
          ],
        },
      ],
    },
    {
      key: 3,
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
  ],
});
