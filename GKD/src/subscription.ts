import { defineGkdSubscription } from '@gkd-kit/define';
import { batchImportApps } from '@gkd-kit/tools';
import categories from './categories';
import globalGroups from './globalGroups';

export default defineGkdSubscription({
  id: 7777777,
  name: 'Ticks的GKD订阅',
  version: 3,
  author: 'Ticks',
  checkUpdateUrl: './gkd.version.json5',
  supportUri: 'https://github.com/ticks-tan/me-sub/GKD',
  categories,
  globalGroups,
  apps: await batchImportApps(`${import.meta.dirname}/apps`),
});
