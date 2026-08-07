import type { Language } from "./types";
import ru from "./dictionaries/ru";
import en from "./dictionaries/en";
import tr from "./dictionaries/tr";
import id from "./dictionaries/id";
import ar from "./dictionaries/ar";

export const DICTIONARIES: Record<Language, typeof ru> = { ru, en, tr, id, ar };

type Section = keyof typeof ru;

/** t("balance.history") -> dictionary[lang].balance.history, with {placeholders} filled in. */
export function translate(
  lang: Language,
  key: `${Section}.${string}`,
  vars?: Record<string, string | number>,
): string {
  const [section, field] = key.split(".") as [Section, string];
  const dict = DICTIONARIES[lang][section] as Record<string, string> | undefined;
  let text = dict?.[field] ?? DICTIONARIES.ru[section]?.[field as never] ?? key;

  if (vars) {
    for (const [name, value] of Object.entries(vars)) {
      text = text.replace(`{${name}}`, String(value));
    }
  }

  return text;
}
