/*
 * Стенд для plugin.js. Запускается через pytest (test_plugin.py).
 *
 * ЧТО ЭТО ПРОВЕРЯЕТ: логику плагина — разбор карточки, выбор типа, список
 * сезонов, тело запроса к bridge. Данные карточки берутся из записанных
 * ответов TMDB, а не выдумываются: структура movie в событии 'full' — это
 * ровно то, что источник положил в data.movie.
 *
 * ЧЕГО ЭТО НЕ ПРОВЕРЯЕТ: что плагин работает внутри настоящей Lampa. Здесь
 * подставлены заглушки вместо Lampa, jQuery и DOM, и заглушка всегда ведёт
 * себя так, как её написал автор. Кнопка в интерфейсе, фокус пультом, вид
 * списка сезонов — проверяются руками, см. docs/ACCEPTANCE.md, этап 6.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const RECORDED = path.join(__dirname, 'recorded');
const PLUGIN = path.join(__dirname, '..', 'static', 'plugin.js');

let failures = 0;
function check(name, cond, extra) {
  if (cond) {
    console.log('  [ok]   ' + name);
  } else {
    console.log('  [FAIL] ' + name + (extra ? '\n         ' + extra : ''));
    failures++;
  }
}

// --------------------------------------------------------------------------
// Заглушки окружения
// --------------------------------------------------------------------------

function makeNode(html) {
  const node = {
    html: html || '',
    children: [],
    handlers: {},
    stored: {},
    length: 1,
    on(event, fn) {
      this.handlers[event] = fn;
      return this;
    },
    // .data() — как в jQuery: без второго аргумента геттер, с ним сеттер.
    // Плагин хранит здесь состояние заказа между 'complite' и hover:enter.
    data(key, val) {
      if (val === undefined) return this.stored[key];
      this.stored[key] = val;
      return this;
    },
    find(selector) {
      // 'span' — не дочерний узел, а текст внутри самой кнопки (как в
      // разметке plugin.js). Отдельная ветка, а не элемент children, потому
      // что реальная кнопка тоже создаётся одной строкой html, без DOM.
      if (selector === 'span') {
        const self = this;
        return {
          length: 1,
          text(val) {
            if (val === undefined) {
              const m = self.html.match(/<span>([^<]*)<\/span>/);
              return m ? m[1] : '';
            }
            self.html = self.html.replace(/<span>[^<]*<\/span>/, '<span>' + val + '</span>');
            return this;
          }
        };
      }
      const hits = this.children.filter((c) => c.html.indexOf(selector.replace('.', '')) !== -1);
      const res = hits.length ? hits[0] : makeNode('');
      res.length = hits.length;
      return res;
    },
    after(el) {
      this.parent && this.parent.children.push(el);
      return this;
    },
    append(el) {
      this.children.push(el);
      el.parent = this;
      return this;
    }
  };
  return node;
}

function buildEnv(cardJson, method, opts) {
  opts = opts || {};
  const root = makeNode('root');
  // Кнопка торрентов в карточке есть — плагин цепляется после неё.
  if (!opts.noTorrentButton) {
    const torrent = makeNode('full-start__button view--torrent');
    root.append(torrent);
  }
  const buttons = makeNode('full-start-new__buttons');
  root.append(buttons);

  const calls = { fetch: [], noty: [], select: [], toggle: [] };

  const env = {
    root,
    calls,
    fireFull: null
  };

  global.document = {
    currentScript: { src: 'http://192.168.200.251:8000/plugin.js' },
    getElementsByTagName: () => [],
    createElement: () => ({
      set href(v) {
        const u = new URL(v);
        this.protocol = u.protocol;
        this.host = u.host;
      }
    })
  };

  global.$ = (html) => makeNode(html);

  global.fetch = (url, init) => {
    // GET /status — состояние заказа. По умолчанию отдаём «не ответил»
    // (ok: false): именно так ведёт себя bridge при отказе Radarr/Sonarr,
    // и сценарии, которым состояние безразлично, не должны его выдумывать.
    if (url.indexOf('/status') !== -1) {
      calls.fetch.push({ url, body: null });
      if (opts.status) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(opts.status) });
      }
      return Promise.resolve({ ok: false, json: () => Promise.resolve(null) });
    }
    // GET /profiles — список профилей качества. Отдаём тот же набор, что
    // стоит в Radarr и Sonarr по умолчанию, с отметкой умолчания.
    if (url.indexOf('/profiles') !== -1) {
      calls.fetch.push({ url, body: null });
      return Promise.resolve({
        ok: true,
        json: () =>
          Promise.resolve(
            opts.noProfiles
              ? []
              : [
                  { name: 'Any', default: false },
                  { name: 'HD-720p', default: false },
                  { name: 'HD-1080p', default: true },
                  { name: 'Ultra-HD', default: false }
                ]
          )
      });
    }
    calls.fetch.push({ url, body: JSON.parse(init.body) });
    return Promise.resolve({
      ok: true,
      json: () => Promise.resolve({ status: 'queued', title: 'x', detail: 'принято' })
    });
  };

  global.window = {
    Lampa: {
      Listener: {
        follow: (name, fn) => {
          if (name === 'full') env.fireFull = fn;
        }
      },
      Noty: { show: (t) => calls.noty.push(t) },
      Select: {
        show: (o) => {
          calls.select.push(o);
        }
      },
      Controller: {
        enabled: () => ({ name: 'content' }),
        toggle: (n) => calls.toggle.push(n)
      }
    }
  };
  global.Lampa = global.window.Lampa;
  global.console = console;

  // Плагин — самовызывающаяся функция, просто исполняем исходник.
  const code = fs.readFileSync(PLUGIN, 'utf8');
  new Function(code)();

  env.event = {
    type: 'complite',
    object: { method, activity: { render: () => root } },
    data: { movie: cardJson }
  };
  return env;
}

// --------------------------------------------------------------------------

const movie = JSON.parse(fs.readFileSync(path.join(RECORDED, 'tmdb-movie-10378.json'), 'utf8'));
const tv = JSON.parse(fs.readFileSync(path.join(RECORDED, 'tmdb-tv-1396.json'), 'utf8'));

// Выбор качества идёт через fetch, поэтому проверки после нажатия обязаны
// дождаться промисов. Иначе стенд смотрит на состояние до ответа.
const tick = () => new Promise((r) => setTimeout(r, 0));

async function main() {

console.log('== Фильм');
{
  const env = buildEnv(movie, 'movie');
  check('плагин подписался на full', typeof env.fireFull === 'function');

  // 'build' приходит раньше данных — плагин обязан его игнорировать
  env.fireFull({ type: 'build', object: env.event.object, data: env.event.data });
  const afterBuild = env.root.children.length;

  env.fireFull(env.event);
  check('на build кнопка не добавляется', env.root.children.length === afterBuild + 1);

  const btn = env.root.children[env.root.children.length - 1];
  check('кнопка добавлена', btn && btn.html.indexOf('view--order') !== -1, btn && btn.html);
  check('подписка на hover:enter', btn && typeof btn.handlers['hover:enter'] === 'function');

  btn.handlers['hover:enter']();
  await tick();

  check('спрошено качество', env.calls.select.length === 1);
  const sel = env.calls.select[0];
  check('для фильма сезон не спрашивается', sel && sel.title === 'Качество');
  check(
    'умолчание первым и подписано',
    sel.items[0].profile === 'HD-1080p' && sel.items[0].title.indexOf('по умолчанию') !== -1,
    JSON.stringify(sel.items[0])
  );
  check('список профилей от bridge, не зашит', sel.items.length === 4);

  sel.onSelect({ profile: 'Ultra-HD' });
  await tick();

  const req = env.calls.fetch.filter((c) => c.body)[0];
  check('выбранный профиль ушёл в заказ', req.body.profile === 'Ultra-HD', JSON.stringify(req.body));
  check('type=movie, season=null', req.body.type === 'movie' && req.body.season === null);
}

console.log('== Сериал: сначала сезон, потом качество');
{
  const env = buildEnv(tv, 'tv');
  env.fireFull(env.event);
  const btn = env.root.children[env.root.children.length - 1];
  btn.handlers['hover:enter']();
  await tick();

  check('первым спрошен сезон', env.calls.select.length === 1 && env.calls.select[0].title.indexOf('сезон') !== -1,
    env.calls.select[0] && env.calls.select[0].title);

  const seasons = env.calls.select[0].items.map((i) => i.season);
  const expected = tv.seasons.filter((s) => s.episode_count > 0).map((s) => s.season_number);
  check('сезоны совпали с данными карточки', JSON.stringify(seasons) === JSON.stringify(expected),
    'плагин: ' + JSON.stringify(seasons) + '  данные: ' + JSON.stringify(expected));

  env.calls.select[0].onSelect({ season: 2 });
  await tick();

  check('вторым спрошено качество', env.calls.select.length === 2 && env.calls.select[1].title === 'Качество');
  env.calls.select[1].onSelect({ profile: 'HD-720p' });
  await tick();

  const req = env.calls.fetch.filter((c) => c.body)[0];
  check('в заказе и сезон, и профиль',
    req.body.season === 2 && req.body.profile === 'HD-720p', JSON.stringify(req.body));
  check('фокус возвращён после обоих списков', env.calls.toggle.length >= 2);
}

console.log('== Профили недоступны — заказ не срывается');
{
  const env = buildEnv(movie, 'movie', { noProfiles: true });
  env.fireFull(env.event);
  env.root.children[env.root.children.length - 1].handlers['hover:enter']();
  await tick();
  await tick();

  check('список качества не показан', env.calls.select.length === 0);
  const req = env.calls.fetch.filter((c) => c.body)[0];
  check('заказ всё равно ушёл', !!req);
  check('поле profile не отправлено — bridge подставит умолчание',
    req && !('profile' in req.body), req && JSON.stringify(req.body));
}

console.log('== Адрес bridge и запасной якорь');
{
  const env = buildEnv(movie, 'movie', { noTorrentButton: true });
  env.fireFull(env.event);
  const buttons = env.root.children.find((c) => c.html.indexOf('full-start-new__buttons') !== -1);
  check('кнопка легла в блок кнопок', buttons.children.some((c) => c.html.indexOf('view--order') !== -1));

  // Кнопка здесь лежит ВНУТРИ блока кнопок, а не в корне — иначе якорь бы не
  // проверялся.
  const orderBtn = buttons.children.find((c) => c.html.indexOf('view--order') !== -1);
  orderBtn.handlers['hover:enter']();
  await tick();
  check('адрес bridge выведен из адреса плагина',
    env.calls.fetch[0].url.indexOf('http://192.168.200.251:8000/') === 0, env.calls.fetch[0].url);
}

console.log('');
if (failures) {
  console.log('ИТОГ: НЕ ПРОШЛО (' + failures + ')');
  process.exit(1);
}
console.log('ИТОГ: прошло');
}

// --------------------------------------------------------------------------
// Отдельные сценарии для pytest: каждый проверяет одну вещь и печатает то,
// что нужно найти в stdout, — без карточек check(), в отличие от main().
// --------------------------------------------------------------------------

// Карточка минимальна: для проверки состояния не нужны ни постеры, ни сезоны,
// а tmdb_id взят так, чтобы не совпасть ни с одним фиктивным id из recorded/.
const statusCard = { id: 1083381, title: 'Тест' };

async function scenarioStatusRequest() {
  const env = buildEnv(statusCard, 'movie');
  env.fireFull(env.event);
  await tick();
  console.log(env.calls.fetch[0].url);
}

async function scenarioStatusLabel() {
  const status = {
    state: 'downloading',
    label: 'Закачивается 44%',
    detail: null,
    can_order: false
  };
  const env = buildEnv(statusCard, 'movie', { status });
  env.fireFull(env.event);
  await tick();
  const btn = env.root.children[env.root.children.length - 1];
  console.log(btn.html);
}

// 'complite' приходит и при возврате в карточку (см. addButton), не только
// при первом открытии. Ранний return по найденной кнопке обязан гасить не
// только повторную кнопку, но и повторный запрос /status — иначе при
// каждом возврате в карточку копился бы ещё один fetch.
async function scenarioReopenCard() {
  const env = buildEnv(statusCard, 'movie');
  env.fireFull(env.event);
  await tick();
  env.fireFull(env.event);
  await tick();
  const buttons = env.root.find('.view--order').length;
  const statusRequests = env.calls.fetch.filter((c) => c.url.indexOf('/status') !== -1).length;
  console.log('buttons=' + buttons);
  console.log('status-requests=' + statusRequests);
}

const scenario = process.argv[2];
if (scenario === 'status-request') {
  scenarioStatusRequest();
} else if (scenario === 'status-label') {
  scenarioStatusLabel();
} else if (scenario === 'reopen-card') {
  scenarioReopenCard();
} else {
  main();
}
