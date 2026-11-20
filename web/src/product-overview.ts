import type { PublicLanguage } from './public-pages-content.js';

const copy = {
  en: {
    title: 'One grocery list for dinner and tomorrow’s lunch.',
    lead: 'Make your grocery list on iPhone, compare the cost of buying enough food, and set aside the portions you want to keep.',
    guide: 'See how to compare packs',
    example: 'A pack comparison on iPhone',
    exampleText: 'For 12 tortillas, two 8-packs at $3.20 cost $6.40. Two 6-packs at $2.70 give you exactly 12 for $5.40.',
    alt: 'The Compare packs screen shows Pack A at $6.40 and Pack B at $5.40 for 12 flour tortillas. These totals cover tortillas only.',
    heading: 'From your list to your table',
    steps: [
      ['Build the pickup', 'Put quantities and notes on your list. Enter pack prices and sizes to compare them as you shop, even offline.'],
      ['Set aside lunch', 'Choose a dinner, check what you have in the pantry, and reserve the servings you want for the next day.'],
      ['Check what came home', 'Record how much you received and can use. If a pack comes up short, see which meal needs adjusting.']
    ],
    operator: 'Room in the Cart is made by',
    nav: 'Product information', help: 'Help', support: 'Support', privacy: 'Privacy', terms: 'Terms'
  },
  es: {
    title: 'Una lista de compras para la cena y el almuerzo de mañana.',
    lead: 'Haz la lista en tu iPhone, compara cuánto cuesta comprar la cantidad que necesitas y aparta las porciones que quieres guardar.',
    guide: 'Ver cómo comparar paquetes',
    example: 'Comparación de paquetes en iPhone',
    exampleText: 'Para llevar 12 tortillas, dos paquetes de 8 a $3.20 cuestan $6.40. Con dos paquetes de 6 a $2.70 te llevas justo 12 por $5.40.',
    alt: 'La pantalla de comparación muestra el paquete A a $6.40 y el B a $5.40 para 12 tortillas de harina. Los totales solo incluyen las tortillas.',
    heading: 'De la lista a la mesa',
    steps: [
      ['Arma la lista', 'Anota las cantidades y los detalles. Ingresa el precio y el tamaño de los paquetes para compararlos al hacer la compra, incluso sin conexión.'],
      ['Aparta el almuerzo', 'Elige una cena, revisa lo que tienes en la despensa y aparta las porciones que quieres guardar para el día siguiente.'],
      ['Revisa qué llegó', 'Anota cuánto recibiste y cuánto puedes usar. Si un paquete trae menos de lo esperado, revisa qué comida tendrás que ajustar.']
    ],
    operator: 'Room in the Cart es una app de',
    nav: 'Información del producto', help: 'Ayuda', support: 'Soporte', privacy: 'Privacidad', terms: 'Términos'
  }
} as const;

export function renderProductOverview(root: HTMLElement, language: PublicLanguage, operatorName: string | null): void {
  const document = root.ownerDocument;
  const text = copy[language];
  const element = <K extends keyof HTMLElementTagNameMap>(tag: K, value?: string): HTMLElementTagNameMap[K] => {
    const node = document.createElement(tag);
    if (value) node.textContent = value;
    return node;
  };
  const link = (label: string, destination: string, fragment = '') => {
    const node = element('a', label);
    node.href = '/' + destination + '?lang=' + language + fragment;
    return node;
  };

  document.title = language === 'en' ? 'Grocery lists and meal planning · Room in the Cart' : 'Lista de compras y plan de comidas · Room in the Cart';
  const main = element('main');
  main.id = 'public-main';
  main.tabIndex = -1;
  const hero = element('section');
  hero.className = 'overview-hero';
  const introduction = element('div');
  introduction.className = 'overview-intro';
  const guide = link(text.guide, 'help', '#public-section-1');
  guide.className = 'overview-action';
  introduction.append(element('h1', text.title), element('p', text.lead), guide);
  const figure = element('figure');
  figure.className = 'overview-example';
  const screen = element('img');
  screen.src = '/overview/compare-packs-' + (language === 'en' ? 'en-US' : 'es-MX') + '.jpg';
  screen.width = 624;
  screen.height = 1356;
  screen.alt = text.alt;
  const caption = element('figcaption');
  caption.append(element('strong', text.example), element('p', text.exampleText));
  figure.append(screen, caption);
  hero.append(introduction, figure);
  const guideSection = element('section');
  guideSection.className = 'overview-steps';
  const heading = element('h2', text.heading);
  const topics = element('div');
  topics.className = 'overview-topics';
  for (const [title, description] of text.steps) {
    const item = element('section');
    item.append(element('h3', title), element('p', description));
    topics.append(item);
  }
  guideSection.append(heading, topics);
  main.append(hero, guideSection);
  const footer = element('footer');
  footer.className = 'overview-footer';
  if (operatorName) footer.append(element('p', text.operator + ' ' + operatorName + '.'));
  const navigation = element('nav');
  navigation.setAttribute('aria-label', text.nav);
  for (const route of ['help', 'support', 'privacy', 'terms'] as const) navigation.append(link(text[route], route));
  footer.append(navigation);
  root.append(main, footer);
}
