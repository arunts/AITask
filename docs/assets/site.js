// Small progressive enhancements. Every page works without this file.
(function () {
  // Copy buttons: <button class="copy" data-copy="#id">
  document.querySelectorAll('.copy[data-copy]').forEach(function (button) {
    button.addEventListener('click', function () {
      var target = document.querySelector(button.getAttribute('data-copy'));
      if (!target || !navigator.clipboard) return;
      navigator.clipboard.writeText(target.textContent).then(function () {
        var label = button.textContent;
        button.textContent = 'Copied';
        setTimeout(function () { button.textContent = label; }, 1400);
      });
    });
  });

  // Table of contents: highlight the section in view.
  var toc = document.querySelector('.toc');
  if (toc && 'IntersectionObserver' in window) {
    var links = Array.prototype.slice.call(toc.querySelectorAll('a[href^="#"]'));
    var byId = {};
    links.forEach(function (a) { byId[a.getAttribute('href').slice(1)] = a; });
    var headings = Object.keys(byId).map(function (id) { return document.getElementById(id); }).filter(Boolean);
    var current = null;
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          if (current) current.classList.remove('active');
          current = byId[entry.target.id];
          if (current) current.classList.add('active');
        }
      });
    }, { rootMargin: '0px 0px -70% 0px', threshold: 0 });
    headings.forEach(function (h) { observer.observe(h); });
  }

  // Task repository filters.
  var data = document.getElementById('task-data');
  var list = document.getElementById('task-list');
  if (!data || !list) return;
  var tasks = JSON.parse(data.textContent);
  var cards = {};
  Array.prototype.forEach.call(list.children, function (card) { cards[card.getAttribute('data-slug')] = card; });
  var search = document.getElementById('task-search');
  var filters = Array.prototype.slice.call(document.querySelectorAll('.filter'));
  var count = document.getElementById('task-count');
  var empty = document.getElementById('task-empty');
  var clear = document.getElementById('filter-clear');

  var state = { q: '', tags: {}, needs: null, interactive: false };

  function matches(task) {
    if (state.q) {
      var hay = (task.name + ' ' + task.description + ' ' + task.tags.join(' ') + ' ' + task.search).toLowerCase();
      if (state.q.split(/\s+/).some(function (word) { return word && hay.indexOf(word) < 0; })) return false;
    }
    for (var tag in state.tags) {
      if (state.tags[tag] && task.tags.indexOf(tag) < 0) return false;
    }
    if (state.needs && task.needs !== state.needs) return false;
    if (state.interactive && !task.interactive) return false;
    return true;
  }

  function apply() {
    var shown = 0;
    tasks.forEach(function (task) {
      var ok = matches(task);
      cards[task.slug].hidden = !ok;
      if (ok) shown++;
    });
    var noun = tasks.length === 1 ? ' task' : ' tasks';
    count.textContent = shown === tasks.length ? tasks.length + noun : shown + ' of ' + tasks.length + noun;
    empty.hidden = shown > 0;
    var active = !!state.q || state.needs || state.interactive || Object.keys(state.tags).some(function (t) { return state.tags[t]; });
    clear.hidden = !active;
    try {
      var params = new URLSearchParams();
      if (state.q) params.set('q', state.q);
      var tags = Object.keys(state.tags).filter(function (t) { return state.tags[t]; });
      if (tags.length) params.set('tag', tags.join(','));
      if (state.needs) params.set('needs', state.needs);
      if (state.interactive) params.set('interactive', '1');
      var qs = params.toString();
      history.replaceState(null, '', qs ? '?' + qs : location.pathname);
    } catch (e) {}
  }

  function setPressed(button, on) { button.setAttribute('aria-pressed', on ? 'true' : 'false'); }

  filters.forEach(function (button) {
    button.addEventListener('click', function () {
      var kind = button.getAttribute('data-kind');
      var value = button.getAttribute('data-value');
      if (kind === 'tag') {
        state.tags[value] = !state.tags[value];
        setPressed(button, state.tags[value]);
      } else if (kind === 'needs') {
        state.needs = state.needs === value ? null : value;
        filters.filter(function (b) { return b.getAttribute('data-kind') === 'needs'; })
          .forEach(function (b) { setPressed(b, b.getAttribute('data-value') === state.needs); });
      } else if (kind === 'interactive') {
        state.interactive = !state.interactive;
        setPressed(button, state.interactive);
      }
      apply();
    });
  });

  search.addEventListener('input', function () { state.q = search.value.trim().toLowerCase(); apply(); });
  clear.addEventListener('click', function () {
    state = { q: '', tags: {}, needs: null, interactive: false };
    search.value = '';
    filters.forEach(function (b) { setPressed(b, false); });
    apply();
  });

  // Restore filters from the URL so links to a filtered view work.
  try {
    var params = new URLSearchParams(location.search);
    if (params.get('q')) { search.value = params.get('q'); state.q = search.value.trim().toLowerCase(); }
    (params.get('tag') || '').split(',').filter(Boolean).forEach(function (t) { state.tags[t] = true; });
    if (params.get('needs')) state.needs = params.get('needs');
    if (params.get('interactive')) state.interactive = true;
    filters.forEach(function (b) {
      var kind = b.getAttribute('data-kind'), value = b.getAttribute('data-value');
      setPressed(b, (kind === 'tag' && state.tags[value]) || (kind === 'needs' && state.needs === value) || (kind === 'interactive' && state.interactive));
    });
  } catch (e) {}
  apply();
})();
