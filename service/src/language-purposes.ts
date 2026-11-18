import {receiptAliasRoute, requestDuplicateRoute} from './duplicate-assistance.js';
import {foodKeeperMatchRoute} from './foodkeeper-match.js';
import {naturalListRoute} from './language-assistance.js';
import {mealChoiceRoute} from './meal-choice.js';
import {mealExplanationsRoute} from './meal-explanations.js';
import {mealPreferenceRoute, mealFeedbackRoute} from './meal-language-assistance.js';

export const languagePurposes = [
  naturalListRoute, receiptAliasRoute, requestDuplicateRoute, foodKeeperMatchRoute,
  mealChoiceRoute, mealExplanationsRoute, mealPreferenceRoute, mealFeedbackRoute
];
