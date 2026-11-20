// The public and invited mastheads use the same local decorative mark in CSS.
export function brandName(document: Document): HTMLSpanElement {
  const label = document.createElement('span');
  label.className = 'brand-name';
  label.textContent = 'Room in the Cart';
  return label;
}
