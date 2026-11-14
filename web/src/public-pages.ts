import { publicPages, type PublicLanguage, type PublicPageKey } from './public-pages-content.js';
import { publicSiteConfiguration, type PublicSiteConfiguration } from './public-site-configuration.js';

const pageKeys: readonly PublicPageKey[] = ['help', 'privacy', 'terms', 'support'];
const labels = {
  skip: { en: 'Skip to content', es: 'Saltar al contenido' },
  language: { en: 'Language', es: 'Idioma' },
  navigation: { en: 'Information pages', es: 'Páginas de información' },
  contents: { en: 'On this page', es: 'En esta página' },
  invited: { en: 'Open the invited app', es: 'Abrir la app por invitación' },
  support: { en: 'Contact support', es: 'Contactar con soporte' },
  emailSupport: { en: 'Email support', es: 'Enviar correo a soporte' },
  operator: { en: 'Operator', es: 'Operador' },
  footer: {
    en: 'You can read these pages without signing in.',
    es: 'Puedes leer estas páginas sin iniciar sesión.'
  }
} as const;

export function publicPageKey(pathname: string): PublicPageKey | null {
  const match = /^\/(help|privacy|terms|support)\/?$/.exec(pathname);
  return match ? match[1] as PublicPageKey : null;
}

export function operatorDisplayName(raw: unknown): string | null {
  if (typeof raw !== 'string' || !raw || raw.trim() !== raw || raw.includes('$(')
    || new TextEncoder().encode(raw).length > 300 || /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(raw)) return null;
  return raw;
}

export function operatorSupportURL(raw: string | null): URL | null {
  if (typeof raw !== 'string' || !raw || raw.trim() !== raw || raw.includes('$(') || /[\r\n\t]/.test(raw)) return null;
  try {
    const url = new URL(raw);
    if (url.protocol === 'mailto:') {
      const address = url.pathname;
      const parts = address.split('@');
      if (/[?#%]/.test(raw) || url.search || url.hash || address.length > 254 || parts.length !== 2
        || !/^[A-Za-z0-9][A-Za-z0-9._+-]*@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$/.test(address)
        || parts[0]!.length > 64 || parts[0]!.endsWith('.') || parts[0]!.includes('..')
        || parts[1]!.split('.').some(label => label.length > 63)) return null;
      return url;
    }
    const host = url.hostname.toLowerCase();
    if (url.protocol !== 'https:' || !host || url.username || url.password || host === 'localhost'
      || /\.(invalid|test)$/.test(host)
      || ['example.com', 'example.org', 'example.net'].some(domain => host === domain || host.endsWith('.' + domain))) return null;
    return url;
  } catch { return null; }
}

/** Public routes are deliberately independent of WebApp, auth, API and outbox.
 * Call before constructing the invited app. No fetch, cookies or storage are
 * touched, even when an authenticated browser opens a public route.
 */
export function mountPublicPage(root: HTMLElement, configuration: PublicSiteConfiguration = publicSiteConfiguration): boolean {
  const document = root.ownerDocument;
  const window = document.defaultView;
  if (!window) return false;
  const key = publicPageKey(window.location.pathname);
  if (!key) return false;
  const requestedLanguage = new URLSearchParams(window.location.search).get('lang');
  let language: PublicLanguage = requestedLanguage === 'es' || requestedLanguage === 'en'
    ? requestedLanguage : window.navigator.language.toLowerCase().startsWith('es') ? 'es' : 'en';
  const supportURL = operatorSupportURL(configuration.operatorSupportURL);
  const operatorName = operatorDisplayName(configuration.operatorName);
  const anchor = /^#public-section-\d+$/.test(window.location.hash) ? window.location.hash : '';
  // Unknown parameters/fragments are never echoed into links or retained as an
  // invitation secret. Language is the only public-page query parameter.
  window.history.replaceState(null, '', '/' + key + '?lang=' + language + anchor);

  const element = <K extends keyof HTMLElementTagNameMap>(tag: K, text?: string): HTMLElementTagNameMap[K] => {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    return node;
  };
  const render = (restoreLanguageFocus = false): void => {
    const page = publicPages[key];
    root.replaceChildren(); root.classList.add('public-site'); root.dataset.publicPage = key;
    document.documentElement.lang = language;
    document.title = page.title[language] + ' · Room in the Cart';
    const skip = element('a', labels.skip[language]); skip.href = '#public-main'; skip.className = 'public-skip'; root.append(skip);
    const header = element('header');
    const brand = element('a', 'Room in the Cart'); brand.href = '/help?lang=' + language; brand.className = 'public-brand';
    const languageGroup = element('div'); languageGroup.className = 'public-language';
    const languageLabel = element('label', labels.language[language]); languageLabel.htmlFor = 'public-language';
    const languageSelect = element('select'); languageSelect.id = 'public-language';
    for (const [value, title] of [['en', 'English'], ['es', 'Español']] as const) {
      const option = element('option', title); option.value = value; option.selected = language === value; languageSelect.append(option);
    }
    languageSelect.addEventListener('change', () => {
      language = languageSelect.value === 'es' ? 'es' : 'en';
      window.history.replaceState(null, '', '/' + key + '?lang=' + language);
      render(true);
    });
    languageGroup.append(languageLabel, languageSelect); header.append(brand, languageGroup); root.append(header);
    const navigation = element('nav'); navigation.className = 'public-navigation'; navigation.setAttribute('aria-label', labels.navigation[language]);
    for (const route of pageKeys) {
      const link = element('a', publicPages[route].title[language]); link.href = '/' + route + '?lang=' + language;
      if (route === key) link.setAttribute('aria-current', 'page'); navigation.append(link);
    }
    root.append(navigation);
    const main = element('main'); main.id = 'public-main'; main.tabIndex = -1;
    main.append(element('h1', page.title[language]), element('p', page.lead[language]));
    if (operatorName && (key === 'privacy' || key === 'terms')) {
      const operator = element('p', labels.operator[language] + ': ' + operatorName);
      operator.className = 'public-operator'; main.append(operator);
    }
    if (key === 'support' && supportURL) {
      const contact = element('a', supportURL.protocol === 'mailto:' ? labels.emailSupport[language] + ' · ' + supportURL.pathname : labels.support[language]);
      contact.href = supportURL.href; contact.rel = 'noreferrer';
      contact.className = 'public-contact'; main.append(contact);
    } else if (page.notice) {
      const notice = element('aside', page.notice[language]);
      notice.className = 'notice'; notice.setAttribute('role', 'note'); main.append(notice);
    }
    const contents = element('nav'); contents.className = 'public-contents'; contents.setAttribute('aria-label', labels.contents[language]);
    const contentsTitle = element('h2', labels.contents[language]); const contentsList = element('ul');
    page.sections.forEach((section, index) => {
      const row = element('li'); const link = element('a', section.title[language]); link.href = '#public-section-' + index;
      row.append(link); contentsList.append(row);
    });
    contents.append(contentsTitle, contentsList); main.append(contents);
    page.sections.forEach((section, index) => {
      const article = element('section'); article.className = 'public-article'; article.id = 'public-section-' + index;
      const title = element('h2', section.title[language]); title.id = article.id + '-title'; article.setAttribute('aria-labelledby', title.id);
      article.append(title); for (const paragraph of section.paragraphs) article.append(element('p', paragraph[language]));
      main.append(article);
    });
    root.append(main);
    const footer = element('footer'); footer.className = 'public-footer';
    footer.append(element('p', labels.footer[language]));
    const invited = element('a', labels.invited[language]); invited.href = '/requests?lang=' + language; footer.append(invited); root.append(footer);
    if (restoreLanguageFocus) languageSelect.focus();
  };
  render();
  return true;
}
