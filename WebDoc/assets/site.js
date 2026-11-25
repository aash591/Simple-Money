(function () {
  // Landing: type out the rotating second line of the headline.
  var typed = document.getElementById('typed');
  if (typed) {
    var lines = JSON.parse(typed.getAttribute('data-lines'));
    var still = matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (still) {
      typed.textContent = lines[0];
    } else {
      var i = 0, n = 0, erasing = false;
      (function tick() {
        var line = lines[i];
        n += erasing ? -1 : 1;
        typed.textContent = line.slice(0, n);
        var wait = erasing ? 22 : 48;
        if (!erasing && n === line.length) { erasing = true; wait = 2300; }
        else if (erasing && n === 0) { erasing = false; i = (i + 1) % lines.length; wait = 350; }
        setTimeout(tick, wait);
      })();
    }
  }

  // Home: reveal on scroll, header edge, and the SMS -> entry demo.
  var still0 = matchMedia('(prefers-reduced-motion: reduce)').matches;
  var rv = [].slice.call(document.querySelectorAll('.rv'));
  if (rv.length) {
    if (still0 || !('IntersectionObserver' in window)) {
      rv.forEach(function (el) { el.classList.add('in'); });
    } else {
      var io = new IntersectionObserver(function (es) {
        es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } });
      }, { threshold: 0.12, rootMargin: '0px 0px -6% 0px' });
      rv.forEach(function (el) { io.observe(el); });
    }
  }
  var hbar = document.querySelector('.home .bar');
  if (hbar) {
    var onScroll = function () { hbar.classList.toggle('scrolled', window.scrollY > 8); };
    addEventListener('scroll', onScroll, { passive: true });
    onScroll();
  }
  var flow = document.getElementById('how');
  if (flow && !still0 && 'IntersectionObserver' in window) {
    var step = 0, timer = null;
    var run = function () {
      flow.setAttribute('data-step', String(step));
      var wait = step === 2 ? 3200 : 1800;
      step = (step + 1) % 3;
      timer = setTimeout(run, wait);
    };
    new IntersectionObserver(function (es) {
      if (es[0].isIntersecting) { if (!timer) { step = 0; run(); } }
      else { clearTimeout(timer); timer = null; flow.setAttribute('data-step', '2'); }
    }, { threshold: 0.35 }).observe(flow);
  }

  // Mobile navigation drawer toggle for home
  var bar = document.querySelector('.home .bar');
  var toggle = document.querySelector('.home .menu-toggle');
  if (bar && toggle) {
    toggle.addEventListener('click', function () {
      var open = bar.classList.toggle('menu-open');
      toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
    });
    document.addEventListener('click', function (e) {
      if (!bar.contains(e.target) && bar.classList.contains('menu-open')) {
        bar.classList.remove('menu-open');
        toggle.setAttribute('aria-expanded', 'false');
      }
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && bar.classList.contains('menu-open')) {
        bar.classList.remove('menu-open');
        toggle.setAttribute('aria-expanded', 'false');
        toggle.focus();
      }
    });
    var menuLinks = bar.querySelectorAll('.menu a');
    for (var m = 0; m < menuLinks.length; m++) {
      menuLinks[m].addEventListener('click', function () {
        bar.classList.remove('menu-open');
        toggle.setAttribute('aria-expanded', 'false');
      });
    }
  }

  // Guides: counts on the chips, search, and opening the guide named in the URL.
  var search = document.getElementById('search');
  if (!search) return;
  var groups = [].slice.call(document.querySelectorAll('.group'));
  var items = [].slice.call(document.querySelectorAll('.group details'));
  var none = document.getElementById('none');

  groups.forEach(function (g) {
    var chip = document.querySelector('.chips a[href="#' + g.id + '"]');
    if (chip) chip.textContent += ' (' + g.querySelectorAll('details').length + ')';
  });

  function unmark(root) {
    [].slice.call(root.querySelectorAll('mark')).forEach(function (m) {
      m.replaceWith(document.createTextNode(m.textContent));
    });
    root.normalize();
  }
  function mark(root, q) {
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    var nodes = [], node;
    while ((node = walker.nextNode())) nodes.push(node);
    nodes.forEach(function (t) {
      var at = t.nodeValue.toLowerCase().indexOf(q);
      if (at < 0) return;
      var hit = t.splitText(at);
      hit.splitText(q.length);
      var m = document.createElement('mark');
      m.textContent = hit.nodeValue;
      hit.replaceWith(m);
    });
  }

  search.addEventListener('input', function () {
    var q = search.value.trim().toLowerCase();
    var shown = 0;
    items.forEach(function (d) {
      unmark(d);
      var hit = !q || d.textContent.toLowerCase().indexOf(q) >= 0;
      d.hidden = !hit;
      if (hit) shown++;
      if (q.length > 1 && hit) { d.open = true; mark(d, q); }
      else if (!q) d.open = false;
    });
    groups.forEach(function (g) {
      g.hidden = !g.querySelector('details:not([hidden])');
    });
    none.style.display = shown ? 'none' : 'block';
  });

  function openFromHash() {
    var el = location.hash && document.getElementById(location.hash.slice(1));
    if (el && el.tagName === 'DETAILS') { el.open = true; el.scrollIntoView(); }
  }
  addEventListener('hashchange', openFromHash);
  openFromHash();

  // Keep the URL pointing at whichever guide was opened, so it can be shared.
  items.forEach(function (d) {
    d.addEventListener('toggle', function () {
      if (d.open && d.id) history.replaceState(null, '', '#' + d.id);
    });
  });
})();
