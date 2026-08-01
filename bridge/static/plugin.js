/*
 * plugin.js — плагин Lampa. Кнопка «Заказать» в карточке.
 *
 * ТОНКИЙ НАМЕРЕННО. Прочитал id, спросил сезон, отправил один запрос,
 * показал уведомление. Ни ретраев, ни хранения, ни опроса статуса,
 * ни знания об *arr.
 *
 * Причина: внутренности Lampa меняются, плагины при обновлениях отваливаются.
 * В плагине должно быть нечего ломать. Вся хрупкая логика — в bridge, где
 * её можно логировать и тестировать.
 *
 * СЕКРЕТОВ ЗДЕСЬ НЕТ И БЫТЬ НЕ МОЖЕТ. Только адрес bridge. Код исполняется
 * в браузерной странице; если Lampa открыта не со своего хоста, всё её
 * содержимое доступно чужой странице. Проверяется grep'ом, см.
 * docs/ACCEPTANCE.md, этап 6.
 *
 * Отладка: логи bridge. Он пишет каждый входящий запрос — тыкаешь в
 * интерфейсе, смотришь, что реально пришло.
 */

(function () {
  'use strict';

  // Адрес bridge. Плагин отдаётся тем же bridge с того же origin, поэтому
  // относительный путь предпочтителен: CORS не возникает по определению.
  // Абсолютный адрес — только если плагин размещён отдельно.
  var BRIDGE = '';               // '' => тот же origin
  var ORDER_PATH = '/order';

  // -------------------------------------------------------------------------
  // НЕ РЕАЛИЗОВАНО: получение данных карточки.
  //
  // ИЗВЕСТНО ТОЧНО:
  //   - идентификаторы в карточке разрешаются АСИНХРОННО, с задержкой,
  //     особенно когда основной источник — TMDB, а не CUB
  //   - читать сразу при открытии карточки НЕЛЬЗЯ, нужно дождаться полной
  //     загрузки данных
  //   - рабочий основной источник — TMDB; CUB не поддерживается
  //
  // НЕИЗВЕСТНО: какое событие слушать, какой объект опрашивать, где именно
  // лежит тип контента, как корректно добавить кнопку в карточку.
  //
  // ГДЕ УЗНАТЬ (в интернете этого нет, там только каталоги плагинов):
  //   1. npm run doc в yumata/lampa-source -> build/doc/index.html
  //   2. рабочий плагин с исходниками: and7ey/lampa
  //   3. npm run start и смотреть в консоли браузера
  //
  // Создание issue в lampa-source закрыто; вопросы — в Telegram-каналы проекта.
  //
  // НЕ УГАДЫВАТЬ. Открытый вопрос №4 в docs/OPEN-QUESTIONS.md.
  // -------------------------------------------------------------------------

  /**
   * Достаёт {tmdb_id, type, seasons} из полностью загруженной карточки.
   * @returns {{tmdb_id:number, type:'movie'|'tv', seasons:number[]}|null}
   */
  function readCard(/* activity */) {
    throw new Error('readCard не реализован: см. OPEN-QUESTIONS.md, пункт 4');
  }

  /**
   * Подписка на готовность карточки. Обязана срабатывать ПОСЛЕ разрешения
   * идентификаторов, а не при открытии.
   */
  function onCardReady(/* handler */) {
    throw new Error('onCardReady не реализован: см. OPEN-QUESTIONS.md, пункт 4');
  }

  /** Добавляет кнопку в карточку. */
  function addButton(/* label, handler */) {
    throw new Error('addButton не реализован: см. OPEN-QUESTIONS.md, пункт 4');
  }

  /** Выбор сезона. Показывать только для type === 'tv'. */
  function pickSeason(/* seasons, callback */) {
    throw new Error('pickSeason не реализован: см. OPEN-QUESTIONS.md, пункт 4');
  }

  /** Уведомление. Текст берётся из detail ответа bridge и показывается КАК ЕСТЬ. */
  function notify(/* message */) {
    throw new Error('notify не реализован: см. OPEN-QUESTIONS.md, пункт 4');
  }

  // -------------------------------------------------------------------------
  // Реализовано: отправка заказа. Эта часть от внутренностей Lampa не зависит.
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

  function handleOrder(card) {
    function fire(season) {
      sendOrder(
        { tmdb_id: card.tmdb_id, type: card.type, season: season },
        function (err, message) {
          notify(err ? err.message : message);
        }
      );
    }

    if (card.type === 'tv') {
      pickSeason(card.seasons, fire);
    } else {
      fire(null);
    }
  }

  function init() {
    onCardReady(function (activity) {
      var card = readCard(activity);
      if (!card) return;
      addButton('Заказать', function () {
        handleOrder(card);
      });
    });
  }

  init();
})();
