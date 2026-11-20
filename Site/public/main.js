// Deferred. Sections below the first screen wait hidden and come in as they scroll into view;
// what's already on screen (or above) when this runs stays as it is. Nothing is hidden until this
// file has run, so a slow or failed load never blanks the page.
(() => {
  const nav = document.querySelector('.nav');
  const onScroll = () => nav.classList.toggle('scrolled', window.scrollY > 8);
  onScroll();
  window.addEventListener('scroll', onScroll, { passive: true });

  const all = [...document.querySelectorAll('.reveal')];
  const settle = (el) => { el.classList.remove('reveal', 'in'); el.style.transitionDelay = ''; };
  if (!('IntersectionObserver' in window) || matchMedia('(prefers-reduced-motion: reduce)').matches) {
    all.forEach(settle);
    return;
  }
  const fold = window.innerHeight * 0.92;
  const items = all.filter((el) => {
    if (el.getBoundingClientRect().top < fold) { settle(el); return false; }
    return true;
  });
  // Siblings side by side come in one after another (not in one column on phones).
  if (matchMedia('(min-width: 681px)').matches) items.forEach((el) => {
    const group = [...el.parentElement.children].filter((c) => c.classList.contains('reveal'));
    const i = group.indexOf(el);
    if (i > 0) el.style.transitionDelay = `${Math.min(i, 5) * 80}ms`;
  });
  document.documentElement.classList.add('js');

  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (e.isIntersecting) {
        e.target.classList.add('in');
        io.unobserve(e.target);
      }
    }
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
  items.forEach((el) => {
    io.observe(el);
    // Once in, drop the reveal so the element's own transitions (hover) apply.
    el.addEventListener('transitionend', (e) => {
      if (e.target === el && e.propertyName === 'opacity') settle(el);
    });
    // Keyboard focus inside shows it at once.
    el.addEventListener('focusin', () => { el.classList.add('in'); settle(el); });
  });
})();
