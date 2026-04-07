export interface SearchIntent {
  profession: string | null;
  is_urgent: boolean;
  problem_description: string;
  max_radius_km: number | null;
  confidence: number;
  transcribedText?: string;
}

export const VALID_PROFESSIONS = new Set<string>([
  'plumber', 'electrician', 'cleaner', 'painter', 'carpenter',
  'gardener', 'ac_repair', 'appliance_repair', 'mason', 'mechanic', 'mover',
]);

export const FALLBACK_INTENT: SearchIntent = {
  profession:           null,
  is_urgent:            false,
  problem_description:  '',
  max_radius_km:        null,
  confidence:           0.0,
};
