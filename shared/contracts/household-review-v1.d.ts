export type UUID=string;
export interface ReviewedProjection {shopLabel:string;language:'en'|'es';items:{label:string;amount:string|null;unit:string|null;action:string}[]}
export interface ManagedHelperView {grantId:UUID;shopId:UUID;revision:number;asOf:string;expiresAt:string;mode:'read'|'edit';projection:ReviewedProjection}
export interface HelperReplacement {clientKey:UUID;baseRevision:number;projection:ReviewedProjection}
export interface HelperReplacementReceipt {mutationId:UUID;grantId:UUID;baseRevision:number;revision:number;asOf:string;status:'replaced'}
export type HelperResolution={clientKey:UUID;baseRevision:number;proposalRevision:number;decision:'dismiss'}|{clientKey:UUID;baseRevision:number;proposalRevision:number;decision:'replace';projection:ReviewedProjection};
export interface HelperResolutionReceipt {mutationId:UUID;grantId:UUID;proposalId:UUID;proposalRevision:number;baseRevision:number;revision:number;status:'reviewed'|'dismissed';resolution:'replaced'|'dismissed';resolvedAt:string}
export interface HelperProposalStatus {proposalId:UUID;grantId:UUID;baseRevision:number;proposalRevision:number;correction:string;status:'pending'|'reviewed'|'dismissed';createdAt:string;resolution:{mutationId:UUID;decision:'replaced'|'dismissed';revision:number;resolvedAt:string}|null}
export type SelectableShop={shopId:UUID;createdAt:string;phase:'draft'|'frozen'|'placed'|'closed';role:'contributor'}|{shopId:UUID;createdAt:string;phase:'draft'|'frozen'|'placed'|'closed';role:'shopper';revision:number;authorityEpoch:number};
export interface ShopPage {shops:SelectableShop[];nextCursor:UUID|null}
export interface HelperProposalPage {proposals:HelperProposalStatus[];nextCursor:UUID|null}
