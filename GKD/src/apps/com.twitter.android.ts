import { defineGkdApp } from '@gkd-kit/define';

export default defineGkdApp({
  id: 'com.twitter.android',
  name: '推特（X）',
  groups: [
    {
      key: 1,
      name: '其他广告-推荐卡片',
      desc: '自动关闭帖子列表的推荐卡片',
      enable: false,
      activityIds: ['com.twitter.android.MainActivity'],
      rules: [
        {
          key: 1,
          name: '点击右上角 [更多]',
          matches: [
            'TextView[vid="tweet_promoted_badge_bottom"][text="推荐"] <<n LinearLayout - LinearLayout > ImageView[vid="tweet_curation_action"]',
          ],
          snapshotUrls: 'https://i.gkd.li/i/15286961',
        },
        {
          key: 2,
          name: '点击 [我不喜欢这个广告]',
          preKeys: 1,
          matches: [
            'RecyclerView > @ViewGroup > TextView[text="我不喜欢这个广告"]',
          ],
          snapshotUrls: 'https://i.gkd.li/i/15286980',
        },
      ],
    },
  ],
});
