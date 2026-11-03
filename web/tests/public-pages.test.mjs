import assert from 'node:assert/strict';
import test from 'node:test';
import { JSDOM } from 'jsdom';
import { readFileSync } from 'node:fs';
import { mountPublicPage, operatorSupportURL, operatorDisplayName, publicPageKey } from '../dist/public-pages.js';
import { publicPages } from '../dist/public-pages-content.js';
import { publicSiteConfiguration } from '../dist/public-site-configuration.js';

const setup = (path, language = 'en-US', configuration) => {
  const dom = new JSDOM('<div id="app"></div>', { url: 'https://review.grocery-app.com' + path });
  Object.defineProperty(dom.window.navigator, 'language', { value: language });
  const root = dom.window.document.getElementById('app');
  return { dom, root, mounted: mountPublicPage(root, configuration) };
};

test('public routes are exact and do not claim invited or private routes', () => {
  for (const route of ['help', 'privacy', 'terms', 'support']) {
    assert.equal(publicPageKey('/' + route), route);
    assert.equal(publicPageKey('/' + route + '/'), route);
  }
  for (const path of ['/', '/requests', '/invite', '/view', '/v1/help', '/help/private', '/HELP']) {
    const { root, mounted } = setup(path);
    assert.equal(mounted, false); assert.equal(root.children.length, 0);
  }
});

test('every public page renders both languages, one main, named navigation and accessible sections', () => {
  for (const key of Object.keys(publicPages)) for (const language of ['en', 'es']) {
    const { dom, root, mounted } = setup('/' + key + '?lang=' + language);
    assert.equal(mounted, true);
    assert.equal(dom.window.document.documentElement.lang, language);
    assert.equal(root.querySelectorAll('main').length, 1);
    assert.equal(root.querySelectorAll('h1').length, 1);
    assert.equal(root.querySelector('h1').textContent, publicPages[key].title[language]);
    assert.equal(root.querySelector('nav a[aria-current="page"]').pathname, '/' + key);
    assert.equal(root.querySelectorAll('.public-article').length, publicPages[key].sections.length);
    for (const section of root.querySelectorAll('.public-article')) assert.ok(dom.window.document.getElementById(section.getAttribute('aria-labelledby')));
    assert.ok(root.querySelector('label[for="public-language"]'));
    assert.equal(root.querySelector('.public-skip').hash, '#public-main');
    for (const page of Object.values(publicPages)) for (const copy of [page.title, page.lead, page.notice, ...page.sections.flatMap(section => [section.title, ...section.paragraphs])]) {
      assert.deepEqual(Object.keys(copy).sort(), ['en', 'es']);
      assert.ok(copy.en.trim()); assert.ok(copy.es.trim());
    }
  }
});

test('public help never calls account APIs, reads credentials or opens browser storage', t => {
  const dom = new JSDOM('<div id="app"></div>', { url: 'https://review.grocery-app.com/help?token=query-secret#token=fragment-secret' });
  dom.window.fetch = () => { throw new Error('Public pages must not fetch'); };
  const previousFetch = globalThis.fetch;
  globalThis.fetch = () => { throw new Error('Public pages must not fetch'); };
  t.after(() => { globalThis.fetch = previousFetch; });
  for (const name of ['localStorage', 'sessionStorage', 'indexedDB']) Object.defineProperty(dom.window, name, { get() { throw new Error('Public pages must not access storage'); } });
  Object.defineProperty(dom.window.document, 'cookie', { get() { throw new Error('Public pages must not read cookies'); } });
  const root = dom.window.document.getElementById('app');
  assert.equal(mountPublicPage(root), true);
  assert.equal(dom.window.location.href, 'https://review.grocery-app.com/help?lang=en');
  assert.doesNotMatch(root.textContent, /query-secret|fragment-secret/);
  assert.equal(root.querySelectorAll('script,iframe,form,input,textarea').length, 0);
  assert.equal(root.querySelectorAll('a[href*="token"]').length, 0);
});

test('language selection updates public links, text and address without losing focus or storing data', () => {
  const { dom, root } = setup('/privacy', 'es-US');
  assert.equal(dom.window.document.documentElement.lang, 'es');
  const select = root.querySelector('select'); select.value = 'en'; select.dispatchEvent(new dom.window.Event('change'));
  assert.equal(dom.window.location.search, '?lang=en');
  assert.equal(root.querySelector('h1').textContent, 'Privacy and data');
  assert.equal(dom.window.document.activeElement.id, 'public-language');
  for (const link of root.querySelectorAll('.public-navigation a')) assert.equal(link.search, '?lang=en');
  assert.equal(dom.window.localStorage.length, 0);
});

test('privacy and terms disclose remaining operator gates and support uses the supplied address', () => {
  assert.match(setup('/privacy').root.textContent, /not a complete operator-approved release privacy policy/);
  assert.match(setup('/privacy').root.textContent, /Existing local feedback, grocery text, prices and member names are not sent/);
  assert.match(setup('/privacy').root.textContent, /select and review them/);
  assert.match(setup('/terms').root.textContent, /Operator-approved release terms.*pending/);
  const support = setup('/support').root;
  assert.equal(support.querySelector('.public-contact').href, 'mailto:hello@roominthecart.com');
  assert.match(support.textContent, /hello@roominthecart.com/);
  assert.doesNotMatch(support.textContent, /support destination has not been configured|guaranteed savings|successful purchase/);
  const unconfigured = setup('/support', 'en-US', { operatorSupportURL: null }).root;
  assert.match(unconfigured.textContent, /support destination has not been configured/);
  assert.equal(unconfigured.querySelector('.public-contact'), null);
});

test('only a configured public HTTPS contact appears and unsafe configuration is never made clickable', () => {
  for (const raw of [null, '', 'http://support.grocery-app.com', 'javascript:alert(1)', 'https://person:secret@support.grocery-app.com', 'https://support.invalid', 'https://example.com', '$(SUPPORT_URL)', ' https://support.grocery-app.com']) {
    assert.equal(operatorSupportURL(raw), null);
    assert.equal(setup('/support', 'en-US', { operatorSupportURL: raw }).root.querySelector('.public-contact'), null);
  }
  const { root } = setup('/support?lang=es', 'en-US', { operatorSupportURL: 'https://support.grocery-app.com/contact' });
  assert.equal(root.querySelector('.public-contact').href, 'https://support.grocery-app.com/contact');
  assert.match(root.textContent, /destino configurado del operador/);
  assert.doesNotMatch(root.textContent, /No se ha configurado un destino/);
});

test('support mailto accepts only a bare address with no headers, query or encoded payload', () => {
  const url = operatorSupportURL('mailto:hello@roominthecart.com');
  assert.equal(url.href, 'mailto:hello@roominthecart.com');
  assert.equal(url.search, ''); assert.equal(url.hash, '');
  for (const raw of ['mailto:hello@roominthecart.com?', 'mailto:hello@roominthecart.com#', 'mailto:hello@roominthecart.com?subject=hello', 'mailto:hello@roominthecart.com?bcc=another@roominthecart.com', 'mailto:hello@roominthecart.com\r\nBcc:another@roominthecart.com', 'mailto:hello%0d%0a@roominthecart.com', 'mailto:hello@roominthecart.com#body', 'mailto:hello..another@roominthecart.com', 'mailto:hello@-roominthecart.com', 'mailto:hello@roominthecart..com', 'mailto:hello@roominthecart.com,another@roominthecart.com']) {
    assert.equal(operatorSupportURL(raw), null, raw);
    assert.equal(setup('/support', 'en-US', { operatorSupportURL: raw }).root.querySelector('.public-contact'), null);
  }
});

test('supplied operator identity appears on both policy pages in both languages and matches native public defaults', () => {
  const canonical = JSON.parse(readFileSync(new URL('../../config/public-contact.json', import.meta.url), 'utf8'));
  assert.equal(publicSiteConfiguration.operatorName, canonical.operatorName);
  assert.equal(publicSiteConfiguration.operatorSupportURL, 'mailto:' + canonical.supportEmail);
  assert.equal(operatorDisplayName('Venture House Group LLC'), 'Venture House Group LLC');
  for (const route of ['privacy', 'terms']) for (const language of ['en', 'es']) {
    const { root } = setup('/' + route + '?lang=' + language);
    assert.match(root.querySelector('.public-operator').textContent, /Venture House Group LLC/);
    assert.doesNotMatch(root.textContent, /operating legal identity.*pending|operator identity.*pending|identidad legal del operador.*pendiente/);
  }
  for (const raw of [null, '', ' Venture House Group LLC', 'Venture House Group LLC ', 'Venture\nHouse Group LLC', 'Venture\tHouse Group LLC', 'Venture\0House Group LLC', 'Venture\u202eHouse Group LLC', 'Venture\u2028House Group LLC', '$(OPERATOR_NAME)', 'a'.repeat(301)]) {
    assert.equal(operatorDisplayName(raw), null);
    assert.equal(setup('/privacy', 'en-US', { operatorSupportURL: null, operatorName: raw }).root.querySelector('.public-operator'), null);
  }
});
