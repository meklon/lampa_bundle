/*
 * plugin.js — плагин Lampa. Кнопка «Заказать» в карточке.
 *
 * ТОНКИЙ НАМЕРЕННО. Прочитал id, спросил сезон и качество, отправил один
 * запрос, показал уведомление. Ни ретраев, ни хранения, ни опроса статуса,
 * ни знания об *arr.
 *
 * Список профилей качества плагин НЕ знает — забирает у bridge. Иначе
 * переименованный в Radarr профиль сломал бы заказ, и молча.
 *
 * Причина: внутренности Lampa меняются, плагины при обновлениях отваливаются.
 * В плагине должно быть нечего ломать. Вся хрупкая логика — в bridge, где
 * её можно логировать и тестировать.
 *
 * СЕКРЕТОВ ЗДЕСЬ НЕТ И БЫТЬ НЕ МОЖЕТ. Только адрес bridge, и тот выводится
 * из адреса самого файла. Код исполняется в браузерной странице; если Lampa
 * открыта не со своего хоста, всё её содержимое доступно чужой странице.
 * Проверяется grep'ом, см. docs/ACCEPTANCE.md, этап 6.
 *
 * Отладка: логи bridge. Он пишет каждый входящий запрос — тыкаешь в
 * интерфейсе, смотришь, что реально пришло.
 *
 * ---------------------------------------------------------------------------
 * ОТКУДА ВЗЯТ API. Не из интернета и не по памяти — из исходников Lampa:
 *
 *   src/components/full.js:216
 *     Lampa.Listener.send('full', {type: 'complite', object, data, ...})
 *     отправляется ПОСЛЕ полной загрузки карточки. Это и есть ответ на
 *     «идентификаторы разрешаются асинхронно»: раньше данных просто нет.
 *
 *   src/core/api/sources/tmdb.js:561   — params.method различает 'tv' и 'movie'
 *   src/utils/utils.js:637             — countSeasons(): сезоны с episode_count > 0
 *   src/templates/full/start_new.js:27 — блок .full-start-new__buttons,
 *                                        кнопка = .full-start__button.selector
 *   src/components/full/start.js:81    — .view--torrent скрывается настройкой
 *   src/app.js:272                     — window.Lampa: Listener, Noty, Select,
 *                                        Controller, Activity, Lang
 *   src/interaction/select.js:130      — Select.show({title, items, onSelect, onBack})
 *   src/interaction/noty.js:13         — Noty.show(text, params)
 *
 *   Рабочий образец подписки: plugins/online/online.js:233
 * ---------------------------------------------------------------------------
 */

(function () {
  'use strict';

  // Адрес bridge выводится из адреса этого же файла.
  //
  // Относительный путь не годится: плагин исполняется в странице Lampa, и
  // fetch('/order') ушёл бы на origin Lampa, а не bridge. В production это
  // один и тот же хост, при локальной отладке — разные (Lampa на :3000,
  // bridge на :8000), и там относительный путь молча промахнулся бы.
  //
  // Хардкода адреса нет: он и так известен браузеру — по нему загружен этот
  // файл.
  var BRIDGE = (function () {
    var src = '';
    if (document.currentScript && document.currentScript.src) {
      src = document.currentScript.src;
    } else {
      var tags = document.getElementsByTagName('script');
      for (var i = tags.length - 1; i >= 0; i--) {
        if (tags[i].src && tags[i].src.indexOf('plugin.js') !== -1) {
          src = tags[i].src;
          break;
        }
      }
    }
    if (!src) return '';
    var a = document.createElement('a');
    a.href = src;
    return a.protocol + '//' + a.host;
  })();

  var ORDER_PATH = '/order';
  var PROFILES_PATH = '/profiles';
  var STATUS_PATH = '/status';

  // -------------------------------------------------------------------------
  // Чтение карточки
  // -------------------------------------------------------------------------

  /**
   * Достаёт данные из полностью загруженной карточки.
   * @returns {{tmdb_id:number, type:'movie'|'tv', seasons:number[], title:string}|null}
   */
  function readCard(e) {
    var movie = e.data && e.data.movie;
    if (!movie || !movie.id) return null;

    // Тип берётся из object.method — так его различает и сам источник данных.
    // Наличие number_of_seasons используется лишь как запасной признак, если
    // method почему-то не проставлен.
    var method = e.object && e.object.method;
    var type = method === 'tv' || (!method && movie.number_of_seasons) ? 'tv' : 'movie';

    // Сезоны — только реально существующие. Пустые (episode_count == 0)
    // отбрасываются по той же логике, что в utils.js countSeasons().
    // Сезон 0 (спецвыпуски) остаётся: номер валидный, bridge его принимает.
    var seasons = [];
    if (type === 'tv' && Array.isArray(movie.seasons)) {
      for (var i = 0; i < movie.seasons.length; i++) {
        var s = movie.seasons[i];
        if (s && s.episode_count > 0 && typeof s.season_number === 'number') {
          seasons.push(s.season_number);
        }
      }
    }

    return {
      tmdb_id: movie.id,
      type: type,
      seasons: seasons,
      title: movie.title || movie.name || String(movie.id)
    };
  }

  // -------------------------------------------------------------------------
  // Интерфейс
  // -------------------------------------------------------------------------

  function notify(message) {
    if (window.Lampa && Lampa.Noty) Lampa.Noty.show(message);
    else console.log('[order]', message);
  }

  /**
   * Текущее состояние заказа. Логики здесь нет: bridge присылает готовый
   * текст, плагин его показывает. Инвариант «плагин остаётся тонким».
   */
  function fetchStatus(card, callback) {
    fetch(BRIDGE + STATUS_PATH + '?tmdb_id=' + encodeURIComponent(card.tmdb_id) +
          '&type=' + encodeURIComponent(card.type))
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (s) { callback(s && s.state ? s : null); })
      .catch(function () {
        // Не ответил — значит не знаем. Показываем карточку как раньше,
        // выдуманных состояний быть не должно.
        callback(null);
      });
  }

  function addButton(e, card) {
    var root = e.object.activity.render();

    // 'complite' приходит и при возврате в карточку. Кнопка должна остаться
    // одна.
    if (root.find('.view--order').length) return;

    var btn = $(
      '<div class="full-start__button selector view--order">' +
        '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">' +
        '<path d="M12 3v12m0 0l-4-4m4 4l4-4M4 17v2a2 2 0 002 2h12a2 2 0 002-2v-2" ' +
        'stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>' +
        '</svg>' +
        '<span>Заказать</span>' +
        '</div>'
    );

    btn.on('hover:enter', function () {
      handleOrder(card, btn.data('status') || null, btn);
    });

    // Рядом с кнопкой торрентов, если она есть, иначе в конец блока кнопок:
    // .view--torrent скрывается, когда торренты отключены в настройках.
    var torrent = root.find('.view--torrent');
    if (torrent.length) torrent.after(btn);
    else root.find('.full-start-new__buttons').append(btn);

    // Состояние подгружается отдельно: карточка не должна ждать сеть.
    fetchStatus(card, function (status) {
      if (!status) return;
      btn.data('status', status);
      btn.find('span').text(status.label);
    });
  }

  function pickQuality(card, callback) {
    // Список профилей берётся у bridge, а не зашит здесь: профили заводит и
    // переименовывает человек в Radarr/Sonarr, и зашитый перечень разъехался
    // бы с действительностью молча.
    //
    // Разрешение — не отдельный параметр: в *arr оно часть профиля, который
    // заодно задаёт, до чего файл потом апгрейдится.
    fetch(BRIDGE + PROFILES_PATH + '?type=' + encodeURIComponent(card.type))
      .then(function (r) {
        return r.json();
      })
      .then(function (list) {
        if (!Array.isArray(list) || !list.length) {
          // Профилей не видно — заказываем с умолчанием bridge, а не срываем
          // заказ: без поля profile он подставит значение из окружения.
          callback(null);
          return;
        }

        // Умолчание первым: чаще всего выбирают именно его.
        list.sort(function (a, b) {
          return (b.default ? 1 : 0) - (a.default ? 1 : 0);
        });

        var back = Lampa.Controller.enabled().name;
        Lampa.Select.show({
          title: 'Качество',
          items: list.map(function (p) {
            return {
              title: p.default ? p.name + ' (по умолчанию)' : p.name,
              profile: p.name
            };
          }),
          onSelect: function (item) {
            Lampa.Controller.toggle(back);
            callback(item.profile);
          },
          onBack: function () {
            Lampa.Controller.toggle(back);
          }
        });
      })
      .catch(function () {
        // Не достучались до списка — не мешаем заказу, идём с умолчанием.
        callback(null);
      });
  }

  function pickSeason(card, status, callback) {
    if (!card.seasons.length) {
      // Сезонов в данных нет — не выдумываем номер, говорим прямо.
      notify('У сериала не видно сезонов, заказывать нечего');
      return;
    }

    // Куда вернуть управление после закрытия списка.
    var back = Lampa.Controller.enabled().name;

    // Состояние по сезонам приходит от bridge готовым текстом — плагин
    // только сопоставляет его с номером сезона, не разбирая смысл.
    var byNumber = {};
    if (status && status.seasons) {
      for (var j = 0; j < status.seasons.length; j++) {
        byNumber[status.seasons[j].season] = status.seasons[j].label;
      }
    }
    var items = card.seasons.map(function (n) {
      var title = n === 0 ? 'Спецвыпуски' : 'Сезон ' + n;
      if (byNumber[n]) title += ' — ' + byNumber[n];
      return { title: title, season: n };
    });

    Lampa.Select.show({
      title: 'Какой сезон заказать',
      items: items,
      onSelect: function (item) {
        Lampa.Controller.toggle(back);
        callback(item.season);
      },
      onBack: function () {
        Lampa.Controller.toggle(back);
      }
    });
  }

  // -------------------------------------------------------------------------
  // Отправка заказа. От внутренностей Lampa не зависит.
  // -------------------------------------------------------------------------

  function sendOrder(payload, done) {
    fetch(BRIDGE + ORDER_PATH, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    })
      .then(function (res) {
        return res.json().then(function (body) {
          return { ok: res.ok, body: body };
        });
      })
      .then(function (r) {
        // «Уже в библиотеке» — успех, а не отказ.
        if (r.ok) {
          done(null, r.body.detail || 'принято');
        } else {
          done(new Error(r.body && r.body.detail ? r.body.detail : 'ошибка'));
        }
      })
      .catch(function (e) {
        // Ретраев нет намеренно: bridge без состояния, человек нажмёт ещё раз.
        done(new Error('bridge недоступен: ' + e.message));
      });
  }

  function showStatus(card, status, btn) {
    var back = Lampa.Controller.enabled().name;
    var items = [{ title: status.label, action: 'none' }];
    if (status.detail) items.push({ title: status.detail, action: 'none' });
    items.push({ title: 'Обновить', action: 'refresh' });

    Lampa.Select.show({
      title: card.title,
      items: items,
      onSelect: function (item) {
        Lampa.Controller.toggle(back);
        if (item.action === 'refresh') refresh(card, btn);
      },
      onBack: function () { Lampa.Controller.toggle(back); }
    });
  }

  // Обновление перечитывает состояние и переписывает текст кнопки. Элемент
  // кнопки приходит явно, от addButton через handleOrder и showStatus —
  // поиск по глобальному селектору (`$('.view--order')`) в SPA небезопасен:
  // Lampa держит в DOM карточки, с которых уже ушли, и сеттер jQuery
  // применился бы ко всем найденным элементам разом, переписав состояние
  // на чужой невидимой кнопке.
  function refresh(card, btn) {
    fetchStatus(card, function (status) {
      if (!status) {
        notify('Состояние получить не удалось');
        return;
      }
      btn.data('status', status);
      btn.find('span').text(status.label);
      notify(status.label);
    });
  }

  function handleOrder(card, status, btn) {
    // Заказ уже в работе — показываем что происходит, а не заказываем снова.
    if (status && status.can_order === false) {
      showStatus(card, status, btn);
      return;
    }

    function fire(season, profile) {
      notify('Отправляю: ' + card.title);
      var body = { tmdb_id: card.tmdb_id, type: card.type, season: season };
      // profile необязателен: без него bridge берёт умолчание из окружения.
      // Не отправляем null, чтобы не путать «не выбрано» с «выбрано пусто».
      if (profile) body.profile = profile;
      sendOrder(body, function (err, message) {
        // detail из ответа bridge показывается КАК ЕСТЬ: он человекочитаемый
        // и по-русски, это часть контракта (docs/SPEC.md 2.3).
        notify(err ? err.message : message);
      });
    }

    // Порядок вопросов: сначала «что» (сезон), потом «как» (качество).
    if (card.type === 'tv') {
      pickSeason(card, status, function (season) {
        pickQuality(card, function (profile) {
          fire(season, profile);
        });
      });
    } else {
      pickQuality(card, function (profile) {
        fire(null, profile);
      });
    }
  }

  // -------------------------------------------------------------------------

  function init() {
    if (!window.Lampa || !Lampa.Listener) {
      console.log('[order] Lampa не найдена, плагин не запущен');
      return;
    }

    Lampa.Listener.follow('full', function (e) {
      // Только 'complite'. При 'build' идентификаторы ещё не разрешены — это
      // и есть та асинхронность, из-за которой читать карточку сразу при
      // открытии нельзя.
      if (e.type !== 'complite') return;

      var card = readCard(e);
      if (!card) return;

      addButton(e, card);
    });
  }

  init();
})();
