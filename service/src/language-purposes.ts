import {receiptAliasRoute, requestDuplicateRoute} from './duplicate-assistance.js';
import {foodKeeperMatchRoute} from './foodkeeper-match.js';
import {naturalListRoute} from './language-assistance.js';
import {mealExplanationsRoute} from './meal-explanations.js';
import {mealPreferenceRoute, mealFeedbackRoute} from './meal-language-assistance.js';

export const languagePurposes = [
  naturalListRoute, receiptAliasRoute, requestDuplicateRoute, foodKeeperMatchRoute,
  mealExplanationsRoute, mealPreferenceRoute, mealFeedbackRoute
];
