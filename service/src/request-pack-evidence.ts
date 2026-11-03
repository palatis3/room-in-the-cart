import { z } from 'zod';

function isPositiveInteger(value: string): boolean {
  try {
    return BigInt(value) > 0n;
  } catch {
    return false;
  }
}

const integer = z.string().regex(/^(0|[1-9][0-9]{0,18})$/).refine(value => {
  try {
    return BigInt(value) <= 9223372036854775807n;
  } catch {
    return false;
  }
});
const positiveInteger = integer.refine(isPositiveInteger);
const quantity = z.object({
  numerator: positiveInteger,
  denominator: positiveInteger,
  unit: z.enum(['count', 'gram', 'kilogram', 'ounce', 'pound', 'milliliter', 'liter', 'fluidOunce', 'cup']),
  originalLiteral: z.string().max(2048),
}).strict();

export const reviewedPackEvidenceSchema = z.object({
  version: z.literal(1),
  offerId: z.string().min(1).max(128),
  label: z.string().min(1).max(240),
  needed: quantity,
  usablePerPack: quantity,
  packs: z.number().int().min(1).max(10000),
  unitPriceMinor: z.number().int().min(0).max(1_000_000_000).nullable(),
  productMatchConfirmed: z.literal(true),
  availabilityConfirmed: z.literal(true),
  availablePackLimit: z.number().int().min(0).max(10000).nullable(),
  quoteSource: z.string().min(1).max(2048).refine(value => value.trim().length > 0),
  quoteObservedAt: z.string().datetime({ offset: true }),
  reviewedAt: z.string().datetime({ offset: true }),
}).strict();

export type ReviewedPackEvidence = z.infer<typeof reviewedPackEvidenceSchema>;

const units: Record<ReviewedPackEvidence['needed']['unit'], [string, bigint, bigint]> = {
  count: ['count', 1n, 1n],
  gram: ['mass', 1n, 1n],
  kilogram: ['mass', 1000n, 1n],
  ounce: ['mass', 45359237n, 1600000n],
  pound: ['mass', 45359237n, 100000n],
  milliliter: ['volume', 1n, 1n],
  liter: ['volume', 1000n, 1n],
  fluidOunce: ['volume', 473176473n, 16000000n],
  cup: ['volume', 473176473n, 2000000n],
};

/** Validate the chosen whole-pack projection, not global cheapest or retailer truth. */
export function matchesReviewedPack(
  line: {
    originalItem: string;
    packs: number;
    unitPriceMinor: number | null;
  },
  evidence: ReviewedPackEvidence,
): boolean {
  try {
    if (
      line.originalItem !== evidence.label ||
      line.packs !== evidence.packs ||
      line.unitPriceMinor !== evidence.unitPriceMinor ||
      (evidence.availablePackLimit !== null && evidence.packs > evidence.availablePackLimit)
    ) {
      return false;
    }

    const [neededDimension, neededConversionNumerator, neededConversionDenominator] = units[evidence.needed.unit];
    const [usableDimension, usableConversionNumerator, usableConversionDenominator] = units[evidence.usablePerPack.unit];
    if (neededDimension !== usableDimension) return false;

    const packRatioNumerator =
      BigInt(evidence.needed.numerator) * neededConversionNumerator *
      BigInt(evidence.usablePerPack.denominator) * usableConversionDenominator;
    const packRatioDenominator =
      BigInt(evidence.needed.denominator) * neededConversionDenominator *
      BigInt(evidence.usablePerPack.numerator) * usableConversionNumerator;
    if (packRatioNumerator <= 0n || packRatioDenominator <= 0n) return false;

    const packs = (packRatioNumerator + packRatioDenominator - 1n) / packRatioDenominator;
    return packs === BigInt(evidence.packs) &&
      Date.parse(evidence.quoteObservedAt) <= Date.parse(evidence.reviewedAt) + 300000;
  } catch {
    return false;
  }
}
