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
    length: 1,
    on(event, fn) {
      this.handlers[event] = fn;
      return this;
    },
    find(selector) {
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
  check('выбор сезона для фильма не показывается', env.calls.select.length === 0);
}

console.log('== Сериал');
{
  const env = buildEnv(tv, 'tv');
  env.fireFull(env.event);
  const btn = env.root.children[env.root.children.length - 1];
  btn.handlers['hover:enter']();

  check('показан выбор сезона', env.calls.select.length === 1);
  const sel = env.calls.select[0];

  const numbers = sel.items.map((i) => i.season);
  const expected = tv.seasons.filter((s) => s.episode_count > 0).map((s) => s.season_number);
  check(
    'сезоны совпали с данными карточки',
    JSON.stringify(numbers) === JSON.stringify(expected),
    'плагин: ' + JSON.stringify(numbers) + '  данные: ' + JSON.stringify(expected)
  );
  check(
    'сезон 0 назван спецвыпусками',
    !numbers.includes(0) || sel.items.find((i) => i.season === 0).title === 'Спецвыпуски'
  );

  sel.onSelect({ season: 2 });
  check('фокус возвращён', env.calls.toggle.includes('content'));
}

console.log('== Тело запроса');
{
  const env = buildEnv(movie, 'movie');
  env.fireFull(env.event);
  env.root.children[env.root.children.length - 1].handlers['hover:enter']();

  const req = env.calls.fetch[0];
  check('адрес bridge выведен из адреса плагина', req.url === 'http://192.168.200.251:8000/order', req.url);
  check('tmdb_id из карточки', req.body.tmdb_id === movie.id, String(req.body.tmdb_id));
  check('type=movie', req.body.type === 'movie');
  check('season=null для фильма', req.body.season === null);
}

console.log('== Запасной якорь, когда кнопка торрентов скрыта');
{
  const env = buildEnv(movie, 'movie', { noTorrentButton: true });
  env.fireFull(env.event);
  const buttons = env.root.children.find((c) => c.html.indexOf('full-start-new__buttons') !== -1);
  check('кнопка легла в блок кнопок', buttons.children.some((c) => c.html.indexOf('view--order') !== -1));
}

console.log('');
if (failures) {
  console.log('ИТОГ: НЕ ПРОШЛО (' + failures + ')');
  process.exit(1);
}
console.log('ИТОГ: прошло');
