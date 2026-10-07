import {mount} from '../apps/web/node_modules/svelte/src/index-client.js';
import Review from '../apps/web/src/lib/governance/ChangesetReview.svelte';
const endpoint=location.origin;
mount(Review,{target:document.body,props:{connection:{endpoint,token:'synthetic-user'},canReview:true}});
