(function () {
  "use strict";

  const STORAGE_KEY = "abyssal-trial-mvp-v1";
  const MINT_COST = 5;
  const MINT_VAULT = 3;
  const MINT_PLATFORM_FEE = 2;
  const ENHANCE_COST = 2;
  const MAX_ENHANCEMENTS = 10;
  const MAX_STAT_ENHANCEMENT = 5;
  const BASE_PRIZE_POOL = 50;
  const REST_LIMIT = 7;
  const MAX_HISTORY = 6;
  const PRESET_OPTIONS = ["aggressive", "balanced", "survival"];
  const PRESET_LABELS = {
    aggressive: "激进",
    balanced: "平衡",
    survival: "苟活",
  };
  const RARITY_TABLE = [
    { name: "Common", chance: 60, total: 15, cap: 7 },
    { name: "Uncommon", chance: 25, total: 17, cap: 8 },
    { name: "Rare", chance: 10, total: 19, cap: 9 },
    { name: "Epic", chance: 4, total: 21, cap: 10 },
    { name: "Legendary", chance: 1, total: 23, cap: 10 },
  ];
  const TERRAIN_CARDS = [
    {
      name: "熔岩裂隙",
      description: "事件触发时，所有存活角色各承受 D6 灼烧伤害。",
      apply(ctx) {
        ctx.getLiving().forEach((combatant) => {
          const damage = ctx.rollDie(6, "熔岩灼烧");
          ctx.damageCombatant(combatant, damage, null, "被熔岩灼伤");
        });
      },
    },
    {
      name: "浓雾之地",
      description: "事件触发时，本回合所有命中判定 -5。",
      apply(ctx) {
        ctx.roundState.accuracyPenalty = 5;
        ctx.log("浓雾弥漫，本回合所有命中判定 -5。");
      },
    },
    {
      name: "雷暴",
      description: "事件触发时，有 25% 概率对随机一人造成 20 点伤害。",
      apply(ctx) {
        if (ctx.getLiving().length === 0) {
          return;
        }
        if (Math.random() > 0.25) {
          ctx.log("雷暴酝酿，但本回合无人被雷击中。");
          return;
        }
        const target = pickRandom(ctx.getLiving());
        ctx.damageCombatant(target, 20, null, "被雷暴正面击中");
      },
    },
    {
      name: "混沌祭坛",
      description: "事件触发时，本回合第一次掷骰结果翻倍。",
      apply(ctx) {
        ctx.roundState.doubleNextRoll = true;
        ctx.log("混沌祭坛活化，本回合第一次掷骰结果翻倍。");
      },
    },
    {
      name: "鲜血狂热",
      description: "事件触发时，本回合若打出暴击或奇迹，攻击者回复 10 HP。",
      apply(ctx) {
        ctx.roundState.bloodFrenzy = true;
        ctx.log("鲜血狂热降临，本回合暴击会回复 10 HP。");
      },
    },
    {
      name: "神恩降临",
      description: "事件触发时，本回合所有存活角色视为 LUC +3。",
      apply(ctx) {
        ctx.roundState.lucBonus = 3;
        ctx.log("神恩降临，本回合所有人视为 LUC +3。");
      },
    },
  ];
  const FIRST_NAMES = [
    "夜刃",
    "灰烬",
    "霜眼",
    "狂枝",
    "静潮",
    "黑棘",
    "燃灯",
    "断钢",
    "巡鸦",
    "裂影",
  ];
  const TITLES = [
    "行者",
    "猎手",
    "佣兵",
    "残火",
    "哨兵",
    "祈者",
    "拾荒者",
    "铁卫",
    "试剑人",
    "弃子",
  ];

  const dom = {
    roster: document.getElementById("roster"),
    history: document.getElementById("history"),
    summaryGrid: document.getElementById("summary-grid"),
    rosterCount: document.getElementById("roster-count"),
    emptyRosterTemplate: document.getElementById("empty-roster-template"),
  };

  let state = loadState();

  document.addEventListener("click", handleClick);
  document.addEventListener("change", handleChange);
  document.addEventListener("input", handleInput);

  render();

  function initialState() {
    return {
      balance: 60,
      cycle: 1,
      nextAdventurerId: 1,
      totalDestroyed: 0,
      totalMinted: 0,
      totalEnhancementSpent: 0,
      totalWinnings: 0,
      platformRevenue: 0,
      battleHistory: [],
      adventurers: [],
    };
  }

  function loadState() {
    try {
      const raw = window.localStorage.getItem(STORAGE_KEY);
      if (!raw) {
        return initialState();
      }
      const parsed = JSON.parse(raw);
      return sanitizeState(parsed);
    } catch (error) {
      console.error("Failed to load state:", error);
      return initialState();
    }
  }

  function sanitizeState(candidate) {
    const fallback = initialState();
    if (!candidate || typeof candidate !== "object") {
      return fallback;
    }
    return {
      balance: numeric(candidate.balance, fallback.balance),
      cycle: numeric(candidate.cycle, fallback.cycle),
      nextAdventurerId: numeric(candidate.nextAdventurerId, fallback.nextAdventurerId),
      totalDestroyed: numeric(candidate.totalDestroyed, fallback.totalDestroyed),
      totalMinted: numeric(candidate.totalMinted, fallback.totalMinted),
      totalEnhancementSpent: numeric(candidate.totalEnhancementSpent, fallback.totalEnhancementSpent),
      totalWinnings: numeric(candidate.totalWinnings, fallback.totalWinnings),
      platformRevenue: numeric(candidate.platformRevenue, fallback.platformRevenue),
      battleHistory: Array.isArray(candidate.battleHistory)
        ? candidate.battleHistory.slice(0, MAX_HISTORY)
        : [],
      adventurers: Array.isArray(candidate.adventurers)
        ? candidate.adventurers.map(sanitizeAdventurer)
        : [],
    };
  }

  function sanitizeAdventurer(adventurer) {
    const stats = adventurer && typeof adventurer === "object" ? adventurer : {};
    return {
      id: numeric(stats.id, Date.now()),
      name: String(stats.name || "无名者"),
      rarity: String(stats.rarity || "Common"),
      totalPoints: numeric(stats.totalPoints, 15),
      statCap: numeric(stats.statCap, 7),
      str: numeric(stats.str, 5),
      agi: numeric(stats.agi, 5),
      luc: numeric(stats.luc, 5),
      vault: numeric(stats.vault, MINT_VAULT),
      enhancementCount: numeric(stats.enhancementCount, 0),
      enhancementSpent: numeric(stats.enhancementSpent, 0),
      enhancementByStat: {
        str: numeric(stats.enhancementByStat && stats.enhancementByStat.str, 0),
        agi: numeric(stats.enhancementByStat && stats.enhancementByStat.agi, 0),
        luc: numeric(stats.enhancementByStat && stats.enhancementByStat.luc, 0),
      },
      promptPreset: PRESET_OPTIONS.includes(stats.promptPreset) ? stats.promptPreset : "balanced",
      promptNotes: String(stats.promptNotes || ""),
      battlePlan: stats.battlePlan === "battle" ? "battle" : "rest",
      restStreak: numeric(stats.restStreak, 0),
      status: String(stats.status || "active"),
      wins: numeric(stats.wins, 0),
      matches: numeric(stats.matches, 0),
      championships: numeric(stats.championships, 0),
      killCount: numeric(stats.killCount, 0),
      lastResult: String(stats.lastResult || "待命中"),
    };
  }

  function saveState() {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  }

  function render() {
    renderSummary();
    renderRoster();
    renderHistory();
  }

  function renderSummary() {
    const active = state.adventurers.filter((adventurer) => adventurer.status === "active");
    const queued = active.filter((adventurer) => adventurer.battlePlan === "battle");
    const summaryItems = [
      {
        title: "钱包余额",
        value: `${formatNumber(state.balance)} USDC`,
        subtitle: "本地模拟余额，可用于雇佣与强化",
      },
      {
        title: "活跃冒险者",
        value: `${active.length}`,
        subtitle: `${queued.length} 名已切换为参战`,
      },
      {
        title: "累计收入",
        value: `${formatNumber(state.totalWinnings)} USDC`,
        subtitle: "包括名次奖励与击杀奖励",
      },
      {
        title: "已销毁 Vault",
        value: `${formatNumber(state.totalDestroyed)} USDC`,
        subtitle: "死亡与退休时销毁的份额",
      },
    ];

    dom.summaryGrid.innerHTML = summaryItems
      .map(
        (item) => `
          <article class="metric">
            <p class="metric-title">${escapeHtml(item.title)}</p>
            <p class="metric-value">${escapeHtml(item.value)}</p>
            <p class="metric-subtitle">${escapeHtml(item.subtitle)}</p>
          </article>
        `
      )
      .join("");
  }

  function renderRoster() {
    const active = state.adventurers.filter((adventurer) => adventurer.status === "active");
    dom.rosterCount.textContent = `${active.length} / ${state.adventurers.length} 活跃`;

    if (state.adventurers.length === 0) {
      dom.roster.innerHTML = "";
      dom.roster.appendChild(dom.emptyRosterTemplate.content.cloneNode(true));
      return;
    }

    dom.roster.innerHTML = state.adventurers
      .map((adventurer) => {
        const hp = calculateHp(adventurer.str);
        const totalInvested = MINT_COST + adventurer.enhancementSpent;
        const canEnhanceAny =
          adventurer.status === "active" &&
          adventurer.enhancementCount < MAX_ENHANCEMENTS &&
          state.balance >= ENHANCE_COST;

        return `
          <article class="adventurer-card">
            <header class="adventurer-header">
              <div class="adventurer-title">
                <div class="adventurer-meta">
                  <span class="rarity" data-rarity="${escapeHtml(adventurer.rarity)}">${escapeHtml(
          adventurer.rarity
        )}</span>
                  <span class="pill">Vault ${formatNumber(adventurer.vault)} USDC</span>
                  <span class="pill">投入 ${formatNumber(totalInvested)} USDC</span>
                </div>
                <h3>${escapeHtml(adventurer.name)}</h3>
                <div class="status-line">
                  <span class="badge">Prompt ${escapeHtml(PRESET_LABELS[adventurer.promptPreset])}</span>
                  <span class="badge">最近结果：${escapeHtml(adventurer.lastResult)}</span>
                  <span class="status-pill" data-status="${escapeHtml(resolveStatusKey(adventurer))}">
                    ${escapeHtml(resolveStatusText(adventurer))}
                  </span>
                </div>
              </div>
              <div class="action-row">
                <button
                  type="button"
                  class="button ${adventurer.battlePlan === "battle" ? "button-primary" : ""}"
                  data-action="toggle-plan"
                  data-id="${adventurer.id}"
                  ${adventurer.status !== "active" ? "disabled" : ""}
                >
                  ${adventurer.battlePlan === "battle" ? "已报名本场" : "切换为参战"}
                </button>
                <button
                  type="button"
                  class="button button-danger"
                  data-action="retire"
                  data-id="${adventurer.id}"
                  ${adventurer.status !== "active" ? "disabled" : ""}
                >
                  退休并取回 Vault
                </button>
              </div>
            </header>

            <div class="stat-grid">
              ${renderStat("STR", adventurer.str, `强化 ${adventurer.enhancementByStat.str}`)}
              ${renderStat("AGI", adventurer.agi, `强化 ${adventurer.enhancementByStat.agi}`)}
              ${renderStat("LUC", adventurer.luc, `强化 ${adventurer.enhancementByStat.luc}`)}
              ${renderStat("HP", hp, "40 + STR × 3")}
              ${renderStat("连休", adventurer.restStreak, `上限 ${REST_LIMIT}`)}
              ${renderStat("战绩", `${adventurer.wins} / ${adventurer.matches}`, `${adventurer.championships} 次夺冠`)}
            </div>

            <div class="control-grid">
              <div class="field-group">
                <label class="field-label" for="preset-${adventurer.id}">战斗风格</label>
                <select
                  id="preset-${adventurer.id}"
                  class="select"
                  data-field="promptPreset"
                  data-id="${adventurer.id}"
                  ${adventurer.status !== "active" ? "disabled" : ""}
                >
                  ${PRESET_OPTIONS.map(
                    (option) => `
                      <option value="${option}" ${adventurer.promptPreset === option ? "selected" : ""}>
                        ${PRESET_LABELS[option]}
                      </option>
                    `
                  ).join("")}
                </select>
                <span class="field-help">
                  这个最基础版本只把 Prompt 映射成预设策略；下方备注会保存，但不会参与 AI 决策解析。
                </span>

                <label class="field-label" for="notes-${adventurer.id}">策略备注</label>
                <textarea
                  id="notes-${adventurer.id}"
                  class="textarea"
                  data-field="promptNotes"
                  data-id="${adventurer.id}"
                  ${adventurer.status !== "active" ? "disabled" : ""}
                >${escapeHtml(adventurer.promptNotes)}</textarea>
              </div>

              <div class="field-group">
                <span class="field-label">强化</span>
                <span class="field-help">每次 +1 点，消耗 2 USDC。角色总强化最多 10 次，单项最多 +5。</span>
                <div class="upgrade-grid">
                  ${renderEnhanceButton(adventurer, "str", canEnhanceAny)}
                  ${renderEnhanceButton(adventurer, "agi", canEnhanceAny)}
                  ${renderEnhanceButton(adventurer, "luc", canEnhanceAny)}
                </div>
              </div>
            </div>
          </article>
        `;
      })
      .join("");
  }

  function renderStat(label, value, subtitle) {
    return `
      <div class="stat">
        <p class="stat-label">${escapeHtml(label)}</p>
        <p class="stat-value">${escapeHtml(String(value))}</p>
        <p class="metric-subtitle">${escapeHtml(subtitle)}</p>
      </div>
    `;
  }

  function renderEnhanceButton(adventurer, stat, canEnhanceAny) {
    const disabled =
      adventurer.status !== "active" ||
      !canEnhanceAny ||
      adventurer.enhancementByStat[stat] >= MAX_STAT_ENHANCEMENT;
    return `
      <button
        type="button"
        class="button"
        data-action="enhance"
        data-id="${adventurer.id}"
        data-stat="${stat}"
        ${disabled ? "disabled" : ""}
      >
        ${escapeHtml(stat.toUpperCase())} +1
      </button>
    `;
  }

  function renderHistory() {
    if (state.battleHistory.length === 0) {
      dom.history.innerHTML = `
        <div class="empty-state">
          <p>还没有任何战报。先雇佣角色，再运行一场试炼。</p>
        </div>
      `;
      return;
    }

    dom.history.innerHTML = state.battleHistory
      .map((battle) => {
        const playerHighlights = battle.playerHighlights.length
          ? `<ul class="result-list">${battle.playerHighlights
              .map((item) => `<li>${escapeHtml(item)}</li>`)
              .join("")}</ul>`
          : `<p class="metric-subtitle">本场没有你的角色参战。</p>`;

        const tables = battle.tables
          .map(
            (table) => `
              <details class="battle-details">
                <summary>${escapeHtml(table.title)} · ${escapeHtml(table.terrain)}</summary>
                <ul class="event-list">
                  ${table.events.map((event) => `<li>${escapeHtml(event)}</li>`).join("")}
                </ul>
              </details>
            `
          )
          .join("");

        return `
          <article class="battle-card">
            <div class="battle-head">
              <div>
                <p class="eyebrow">第 ${battle.cycle} 场试炼</p>
                <h3>${escapeHtml(battle.title)}</h3>
              </div>
              <span class="badge">${escapeHtml(battle.timestamp)}</span>
            </div>
            <p class="battle-summary">${escapeHtml(battle.summary)}</p>
            <p class="battle-section-title">玩家战果</p>
            ${playerHighlights}
            ${tables}
          </article>
        `;
      })
      .join("");
  }

  function handleClick(event) {
    const actionTarget = event.target.closest("[data-action]");
    if (!actionTarget) {
      return;
    }

    const { action, id, stat } = actionTarget.dataset;
    if (action === "mint") {
      mintAdventurer();
      return;
    }
    if (action === "run-cycle") {
      runCycle();
      return;
    }
    if (action === "reset") {
      resetGame();
      return;
    }
    if (!id) {
      return;
    }

    const adventurer = getAdventurerById(Number(id));
    if (!adventurer) {
      return;
    }

    if (action === "toggle-plan") {
      togglePlan(adventurer);
      return;
    }
    if (action === "retire") {
      retireAdventurer(adventurer);
      return;
    }
    if (action === "enhance" && stat) {
      enhanceAdventurer(adventurer, stat);
    }
  }

  function handleChange(event) {
    const field = event.target.dataset.field;
    const id = Number(event.target.dataset.id);
    if (!field || !id) {
      return;
    }
    const adventurer = getAdventurerById(id);
    if (!adventurer || adventurer.status !== "active") {
      return;
    }
    if (field === "promptPreset" && PRESET_OPTIONS.includes(event.target.value)) {
      adventurer.promptPreset = event.target.value;
      saveAndRender();
    }
  }

  function handleInput(event) {
    const field = event.target.dataset.field;
    const id = Number(event.target.dataset.id);
    if (field !== "promptNotes" || !id) {
      return;
    }
    const adventurer = getAdventurerById(id);
    if (!adventurer || adventurer.status !== "active") {
      return;
    }
    adventurer.promptNotes = String(event.target.value || "");
    saveState();
  }

  function mintAdventurer() {
    if (state.balance < MINT_COST) {
      window.alert("余额不足，无法雇佣新的冒险者。");
      return;
    }

    const rarity = rollRarity();
    const stats = distributeStats(rarity.total, rarity.cap);
    const adventurer = {
      id: state.nextAdventurerId++,
      name: generateName(),
      rarity: rarity.name,
      totalPoints: rarity.total,
      statCap: rarity.cap,
      str: stats.str,
      agi: stats.agi,
      luc: stats.luc,
      vault: MINT_VAULT,
      enhancementCount: 0,
      enhancementSpent: 0,
      enhancementByStat: { str: 0, agi: 0, luc: 0 },
      promptPreset: "balanced",
      promptNotes: "",
      battlePlan: "rest",
      restStreak: 0,
      status: "active",
      wins: 0,
      matches: 0,
      championships: 0,
      killCount: 0,
      lastResult: "新雇佣，待命中",
    };

    state.balance -= MINT_COST;
    state.totalMinted += MINT_COST;
    state.platformRevenue += MINT_PLATFORM_FEE;
    state.adventurers.unshift(adventurer);
    saveAndRender();
  }

  function togglePlan(adventurer) {
    if (adventurer.status !== "active") {
      return;
    }
    adventurer.battlePlan = adventurer.battlePlan === "battle" ? "rest" : "battle";
    saveAndRender();
  }

  function enhanceAdventurer(adventurer, stat) {
    if (adventurer.status !== "active") {
      return;
    }
    if (state.balance < ENHANCE_COST) {
      window.alert("余额不足，无法强化。");
      return;
    }
    if (adventurer.enhancementCount >= MAX_ENHANCEMENTS) {
      window.alert("这个角色已经达到强化上限。");
      return;
    }
    if (adventurer.enhancementByStat[stat] >= MAX_STAT_ENHANCEMENT) {
      window.alert("这个属性已经达到强化上限。");
      return;
    }

    adventurer[stat] += 1;
    adventurer.enhancementByStat[stat] += 1;
    adventurer.enhancementCount += 1;
    adventurer.enhancementSpent += ENHANCE_COST;
    adventurer.vault += ENHANCE_COST;
    adventurer.lastResult = `${stat.toUpperCase()} 强化完成`;

    state.balance -= ENHANCE_COST;
    state.totalEnhancementSpent += ENHANCE_COST;
    saveAndRender();
  }

  function retireAdventurer(adventurer) {
    if (adventurer.status !== "active") {
      return;
    }
    const refund = roundToOne(adventurer.vault * 0.9);
    const destroyed = roundToOne(adventurer.vault * 0.1);
    adventurer.status = "retired";
    adventurer.battlePlan = "rest";
    adventurer.lastResult = `退休返还 ${formatNumber(refund)} USDC`;
    state.balance += refund;
    state.totalDestroyed += destroyed;
    state.totalWinnings += refund;
    saveAndRender();
  }

  function runCycle() {
    const active = state.adventurers.filter((adventurer) => adventurer.status === "active");
    const queued = active.filter((adventurer) => adventurer.battlePlan === "battle");
    const resting = active.filter((adventurer) => adventurer.battlePlan === "rest");
    const timestamp = new Date().toLocaleString("zh-CN", { hour12: false });
    const highlights = [];

    if (active.length === 0) {
      window.alert("你还没有活跃的冒险者。");
      return;
    }

    resting.forEach((adventurer) => {
      adventurer.restStreak += 1;
      if (adventurer.restStreak >= REST_LIMIT) {
        adventurer.status = "swallowed";
        adventurer.lastResult = "连续休息 7 次，被深渊吞噬";
        highlights.push(`${adventurer.name} 因为连续休息 ${REST_LIMIT} 次被深渊吞噬。`);
      } else {
        adventurer.lastResult = `本场休息，连休 ${adventurer.restStreak}`;
      }
    });

    if (queued.length === 0) {
      state.battleHistory.unshift({
        cycle: state.cycle,
        title: "无人报名，本轮仅处理休息计数",
        timestamp,
        summary: "你没有为任何活跃角色选择参战，因此本轮没有进入 32 人试炼。",
        playerHighlights: highlights.length ? highlights : ["无角色参战。"],
        tables: [],
      });
      state.battleHistory = state.battleHistory.slice(0, MAX_HISTORY);
      state.cycle += 1;
      saveAndRender();
      return;
    }

    const selectedPlayers = shuffleArray([...queued]).slice(0, 32);
    const notSelectedPlayers = queued.filter((adventurer) => !selectedPlayers.includes(adventurer));
    notSelectedPlayers.forEach((adventurer) => {
      adventurer.lastResult = "报名人数超限，本轮未被抽中";
    });

    selectedPlayers.forEach((adventurer) => {
      adventurer.restStreak = 0;
      adventurer.matches += 1;
      adventurer.lastResult = "已进入本场试炼";
    });

    const playerCombatants = selectedPlayers.map((adventurer) => createPlayerCombatant(adventurer));
    const bots = Array.from({ length: Math.max(0, 32 - playerCombatants.length) }, (_, index) =>
      createBotCombatant(index + 1)
    );
    const entrants = shuffleArray([...playerCombatants, ...bots]);
    const tournament = runTournament(entrants);

    applyRewards(tournament, selectedPlayers, highlights);

    const summary = buildBattleSummary(tournament, selectedPlayers, notSelectedPlayers, highlights);
    state.battleHistory.unshift({
      cycle: state.cycle,
      title: `${tournament.champion.name} 夺得本场冠军`,
      timestamp,
      summary,
      playerHighlights: highlights,
      tables: tournament.tableLogs,
    });
    state.battleHistory = state.battleHistory.slice(0, MAX_HISTORY);
    state.cycle += 1;
    saveAndRender();
  }

  function runTournament(entrants) {
    const tableLogs = [];
    const fourthPlace = [];
    const eighthPlace = [];
    const prizePoolTracker = { pool: BASE_PRIZE_POOL, destroyed: 0 };

    const roundOne = chunk(shuffleArray([...entrants]), 4);
    const quarterFinalists = roundOne.map((table, index) =>
      resolveTable(table, `第 1 轮 · 第 ${index + 1} 桌`, tableLogs, prizePoolTracker).winner
    );

    const roundTwo = chunk(shuffleArray([...quarterFinalists]), 4);
    const finalists = roundTwo.map((table, index) => {
      const { winner, runnerUp } = resolveTable(
        table,
        `第 2 轮 · 第 ${index + 1} 桌`,
        tableLogs,
        prizePoolTracker
      );
      table.forEach((combatant) => {
        if (combatant.id === winner.id) {
          return;
        }
        if (runnerUp && combatant.id === runnerUp.id) {
          fourthPlace.push(combatant);
        } else {
          eighthPlace.push(combatant);
        }
      });
      return winner;
    });

    const finalPair = shuffleArray([...finalists]);
    const { winner: champion } = resolveTable(finalPair, "第 3 轮 · 决赛", tableLogs, prizePoolTracker);
    const runnerUp = finalPair.find((combatant) => combatant.id !== champion.id);

    return {
      champion,
      runnerUp,
      fourthPlace,
      eighthPlace,
      prizePool: roundToOne(prizePoolTracker.pool),
      destroyed: roundToOne(prizePoolTracker.destroyed),
      tableLogs,
    };
  }

  function resolveTable(combatants, title, tableLogs, prizePoolTracker) {
    const table = combatants.map((combatant) => resetForBattle(combatant));
    const terrain = pickRandom(TERRAIN_CARDS);
    const events = [];
    const eliminationOrder = [];
    let round = 1;

    const ctx = {
      roundState: {
        accuracyPenalty: 0,
        lucBonus: 0,
        bloodFrenzy: false,
        doubleNextRoll: false,
      },
      getLiving() {
        return table.filter((combatant) => !combatant.dead);
      },
      log(message) {
        events.push(`R${round}: ${message}`);
      },
      rollDie(sides, label) {
        let value = randomInt(1, sides);
        if (ctx.roundState.doubleNextRoll) {
          value *= 2;
          ctx.roundState.doubleNextRoll = false;
          ctx.log(`${label} 触发混沌祭坛，掷骰翻倍为 ${value}。`);
        }
        return value;
      },
      damageCombatant(target, damage, source, reason) {
        if (target.dead) {
          return;
        }
        target.currentHp = Math.max(0, target.currentHp - damage);
        if (source) {
          target.damageTaken[source.id] = (target.damageTaken[source.id] || 0) + damage;
        }
        const sourceLabel = source ? `${source.name} 对 ${target.name}` : target.name;
        ctx.log(`${sourceLabel} ${reason}，造成 ${damage} 伤害，剩余 HP ${target.currentHp}。`);
        if (target.currentHp <= 0) {
          eliminateCombatant(target, source, prizePoolTracker, ctx);
          eliminationOrder.push(target);
        }
      },
    };

    events.push(`${title} 地形：${terrain.name}。${terrain.description}`);

    while (ctx.getLiving().length > 1 && round <= 20) {
      ctx.roundState = {
        accuracyPenalty: 0,
        lucBonus: 0,
        bloodFrenzy: false,
        doubleNextRoll: false,
      };

      if (Math.random() <= 0.2) {
        terrain.apply(ctx);
      }

      const initiativeOrder = shuffleArray([...ctx.getLiving()])
        .map((combatant) => ({
          combatant,
          initiative: combatant.agi + ctx.rollDie(20, `${combatant.name} 的先手判定`),
        }))
        .sort((left, right) => right.initiative - left.initiative)
        .map((entry) => entry.combatant);

      initiativeOrder.forEach((combatant) => {
        if (combatant.dead || ctx.getLiving().length <= 1) {
          return;
        }

        const decision = decideAction(combatant, ctx.getLiving(), round);
        if (decision.action === "wait") {
          ctx.log(`${combatant.name} 选择观望：${decision.reason}`);
          return;
        }
        if (decision.action === "defend") {
          combatant.guardBonus = 4;
          ctx.log(`${combatant.name} 采取防守姿态：${decision.reason}`);
          return;
        }

        const target = decision.target;
        if (!target || target.dead) {
          return;
        }

        const attackRoll =
          combatant.agi + ctx.rollDie(20, `${combatant.name} 的命中判定`) - ctx.roundState.accuracyPenalty;
        const defenseRoll = target.agi + ctx.rollDie(20, `${target.name} 的闪避判定`) + target.guardBonus;

        if (attackRoll < defenseRoll) {
          ctx.log(
            `${combatant.name} 试图攻击 ${target.name}，但命中 ${attackRoll} 低于闪避 ${defenseRoll}。`
          );
          return;
        }

        const baseDamage = combatant.str + ctx.rollDie(10, `${combatant.name} 的伤害骰`);
        const critScore = combatant.luc + ctx.roundState.lucBonus + ctx.rollDie(20, `${combatant.name} 的暴击判定`);
        let multiplier = 1;
        let damageLabel = "普通攻击";

        if (critScore >= 28) {
          multiplier = 3;
          damageLabel = "奇迹一击";
        } else if (critScore >= 22) {
          multiplier = 2;
          damageLabel = "暴击";
        }

        const damage = baseDamage * multiplier;
        ctx.damageCombatant(target, damage, combatant, `${damageLabel}命中`);

        if (multiplier > 1 && ctx.roundState.bloodFrenzy && !combatant.dead) {
          combatant.currentHp = Math.min(combatant.maxHp, combatant.currentHp + 10);
          ctx.log(`${combatant.name} 受到鲜血狂热影响，回复 10 HP，当前 HP ${combatant.currentHp}。`);
        }
      });

      table.forEach((combatant) => {
        combatant.guardBonus = 0;
      });

      round += 1;
    }

    const winner = ctx.getLiving()[0];
    const runnerUp = eliminationOrder.length
      ? eliminationOrder[eliminationOrder.length - 1]
      : null;
    if (!winner) {
      const fallback = shuffleArray([...table]).find((combatant) => !combatant.dead) || table[0];
      tableLogs.push({
        title,
        terrain: terrain.name,
        events: [...events, "本桌出现同归于尽，随机从幸存判定中抽取一名晋级者。"],
      });
      return { winner: fallback, runnerUp };
    }

    events.push(`${winner.name} 成为 ${title} 的晋级者。`);
    tableLogs.push({
      title,
      terrain: terrain.name,
      events,
    });
    return { winner, runnerUp };
  }

  function eliminateCombatant(target, source, prizePoolTracker, ctx) {
    if (target.dead) {
      return;
    }
    target.dead = true;
    target.currentHp = 0;
    if (source) {
      source.killCount += 1;
    }

    const vaultContribution = roundToOne(target.vault * 0.9);
    const destroyed = roundToOne(target.vault * 0.1);
    prizePoolTracker.pool += vaultContribution;
    prizePoolTracker.destroyed += destroyed;
    ctx.log(
      `${target.name} 阵亡，Vault ${formatNumber(target.vault)} USDC 中 ${formatNumber(
        vaultContribution
      )} USDC 进入奖池，${formatNumber(destroyed)} USDC 被销毁。`
    );
  }

  function applyRewards(tournament, selectedPlayers, highlights) {
    state.totalDestroyed += tournament.destroyed;

    const payouts = new Map();
    const placements = new Map();
    payouts.set(tournament.champion.id, roundToOne(tournament.prizePool * 0.5));
    placements.set(tournament.champion.id, "champion");
    payouts.set(tournament.runnerUp.id, roundToOne(tournament.prizePool * 0.2));
    placements.set(tournament.runnerUp.id, "runnerUp");
    tournament.fourthPlace.forEach((combatant) => {
      payouts.set(combatant.id, roundToOne(tournament.prizePool * 0.1));
      placements.set(combatant.id, "fourth");
    });
    tournament.eighthPlace.forEach((combatant) => {
      payouts.set(combatant.id, roundToOne(tournament.prizePool * 0.025));
      placements.set(combatant.id, "eighth");
    });

    const trackedCombatants = [
      tournament.champion,
      tournament.runnerUp,
      ...tournament.fourthPlace,
      ...tournament.eighthPlace,
    ];
    const uniqueCombatants = new Map(trackedCombatants.map((combatant) => [combatant.id, combatant]));

    selectedPlayers.forEach((adventurer) => {
      const combatant = uniqueCombatants.get(adventurer.id);
      const earnedPrize = payouts.get(adventurer.id) || 0;
      const killBonus = combatant ? combatant.killCount * 5 : 0;

      if (earnedPrize > 0) {
        state.balance += earnedPrize;
        state.totalWinnings += earnedPrize;
      }
      if (killBonus > 0) {
        state.balance += killBonus;
        state.totalWinnings += killBonus;
      }
      if (combatant) {
        adventurer.killCount += combatant.killCount;
      }

      const placement = placements.get(adventurer.id);
      const gain = formatNumber(earnedPrize + killBonus);

      if (placement === "champion") {
        adventurer.wins += 1;
        adventurer.championships += 1;
        adventurer.lastResult = `夺冠，获 ${gain} USDC`;
        highlights.push(`${adventurer.name} 夺冠，拿到 ${formatNumber(earnedPrize)} USDC 奖池分成与 ${formatNumber(killBonus)} USDC 击杀奖励。`);
        return;
      }
      if (placement === "runnerUp") {
        adventurer.wins += 1;
        adventurer.lastResult = `亚军，获 ${gain} USDC`;
        highlights.push(`${adventurer.name} 打进决赛，获得 ${gain} USDC。`);
        return;
      }
      if (placement === "fourth") {
        adventurer.wins += 1;
        adventurer.lastResult = `4 强，获 ${gain} USDC`;
        highlights.push(`${adventurer.name} 打进 4 强，获得 ${gain} USDC。`);
        return;
      }
      if (placement === "eighth") {
        adventurer.wins += 1;
        adventurer.lastResult = `8 强，获 ${gain} USDC`;
        highlights.push(`${adventurer.name} 进入 8 强，获得 ${gain} USDC。`);
        return;
      }

      adventurer.status = "dead";
      adventurer.battlePlan = "rest";
      adventurer.lastResult = "在试炼中死亡，NFT 已销毁";
      highlights.push(`${adventurer.name} 在本场试炼中死亡。`);
    });
  }

  function buildBattleSummary(tournament, selectedPlayers, notSelectedPlayers, highlights) {
    const playerCount = selectedPlayers.length;
    const excluded = notSelectedPlayers.length
      ? `另有 ${notSelectedPlayers.length} 名报名角色因超过 32 人上限未被抽中。`
      : "";
    const playerOutcome = highlights.length
      ? highlights[0]
      : "本场参战角色全部在首轮出局。";
    return `本轮共有 ${playerCount} 名玩家角色参战，奖池总额 ${formatNumber(
      tournament.prizePool
    )} USDC，冠军为 ${tournament.champion.name}。${playerOutcome}${excluded}`;
  }

  function decideAction(combatant, living, round) {
    const opponents = living.filter((candidate) => candidate.id !== combatant.id && !candidate.dead);
    if (opponents.length === 0) {
      return { action: "wait", reason: "场上已无对手", target: null };
    }

    const byLowestHp = [...opponents].sort((left, right) => left.currentHp - right.currentHp);
    const byHighestLuc = [...opponents].sort((left, right) => right.luc - left.luc);
    const lowHpTarget = byLowestHp[0];
    const highLucTarget = byHighestLuc[0];
    const healthRatio = combatant.currentHp / combatant.maxHp;

    if (combatant.promptPreset === "survival") {
      if (round === 1) {
        return { action: "wait", reason: "先观察局势，避免第一轮成为集火目标", target: null };
      }
      if (healthRatio < 0.35 && Math.random() < 0.45) {
        return { action: "defend", reason: "当前血量偏低，优先保命", target: null };
      }
      return {
        action: "attack",
        reason: "优先收尾残血目标，再尝试压制高运气对手",
        target: lowHpTarget.currentHp <= highLucTarget.currentHp + 10 ? lowHpTarget : highLucTarget,
      };
    }

    if (combatant.promptPreset === "aggressive") {
      const target = [...opponents].sort((left, right) => {
        const leftScore = left.currentHp - left.agi;
        const rightScore = right.currentHp - right.agi;
        return leftScore - rightScore;
      })[0];
      return {
        action: "attack",
        reason: "压低最容易击杀的目标，尽快拿到击杀奖励",
        target,
      };
    }

    if (healthRatio < 0.25 && Math.random() < 0.25) {
      return { action: "defend", reason: "保持平衡流派，低血量时做一次保守防守", target: null };
    }

    return {
      action: "attack",
      reason: "默认平衡策略，优先攻击当前最容易击倒的对手",
      target: lowHpTarget,
    };
  }

  function createPlayerCombatant(adventurer) {
    return {
      id: adventurer.id,
      sourceId: adventurer.id,
      name: adventurer.name,
      rarity: adventurer.rarity,
      str: adventurer.str,
      agi: adventurer.agi,
      luc: adventurer.luc,
      promptPreset: adventurer.promptPreset,
      vault: adventurer.vault,
      isPlayer: true,
      killCount: 0,
      dead: false,
      currentHp: calculateHp(adventurer.str),
      maxHp: calculateHp(adventurer.str),
      guardBonus: 0,
      damageTaken: {},
    };
  }

  function createBotCombatant(index) {
    const rarity = rollRarity();
    const stats = distributeStats(rarity.total, rarity.cap);
    const enhancementCount = randomInt(0, 4);
    const enhancementByStat = { str: 0, agi: 0, luc: 0 };
    for (let i = 0; i < enhancementCount; i += 1) {
      const stat = pickRandom(["str", "agi", "luc"]);
      if (enhancementByStat[stat] >= MAX_STAT_ENHANCEMENT) {
        i -= 1;
        continue;
      }
      enhancementByStat[stat] += 1;
      stats[stat] += 1;
    }
    return {
      id: 100000 + state.cycle * 100 + index,
      name: `AI ${generateName()}`,
      rarity: rarity.name,
      str: stats.str,
      agi: stats.agi,
      luc: stats.luc,
      promptPreset: pickRandom(PRESET_OPTIONS),
      vault: MINT_VAULT + enhancementCount * ENHANCE_COST,
      isPlayer: false,
      killCount: 0,
      dead: false,
      currentHp: calculateHp(stats.str),
      maxHp: calculateHp(stats.str),
      guardBonus: 0,
      damageTaken: {},
    };
  }

  function resetForBattle(combatant) {
    combatant.dead = false;
    combatant.currentHp = combatant.maxHp;
    combatant.guardBonus = 0;
    combatant.damageTaken = {};
    return combatant;
  }

  function getAdventurerById(id) {
    return state.adventurers.find((adventurer) => adventurer.id === id);
  }

  function resetGame() {
    const confirmed = window.confirm("这会清空当前本地原型中的所有角色与战报，是否继续？");
    if (!confirmed) {
      return;
    }
    state = initialState();
    saveAndRender();
  }

  function saveAndRender() {
    saveState();
    render();
  }

  function rollRarity() {
    const roll = Math.random() * 100;
    let cursor = 0;
    for (const item of RARITY_TABLE) {
      cursor += item.chance;
      if (roll <= cursor) {
        return item;
      }
    }
    return RARITY_TABLE[0];
  }

  function distributeStats(total, cap) {
    const stats = { str: 1, agi: 1, luc: 1 };
    let remaining = total - 3;
    const keys = ["str", "agi", "luc"];

    while (remaining > 0) {
      const key = pickRandom(keys);
      if (stats[key] >= cap) {
        continue;
      }
      stats[key] += 1;
      remaining -= 1;
    }
    return stats;
  }

  function generateName() {
    return `${pickRandom(FIRST_NAMES)}${pickRandom(TITLES)}`;
  }

  function calculateHp(str) {
    return 40 + str * 3;
  }

  function resolveStatusText(adventurer) {
    if (adventurer.status !== "active") {
      return {
        dead: "已死亡",
        swallowed: "已被吞噬",
        retired: "已退休",
      }[adventurer.status];
    }
    return adventurer.battlePlan === "battle" ? "本场参战" : "本场休息";
  }

  function resolveStatusKey(adventurer) {
    return adventurer.status === "active" ? adventurer.battlePlan : adventurer.status;
  }

  function formatNumber(value) {
    return Number(value).toFixed(Number.isInteger(value) ? 0 : 1);
  }

  function randomInt(min, max) {
    return Math.floor(Math.random() * (max - min + 1)) + min;
  }

  function pickRandom(items) {
    return items[randomInt(0, items.length - 1)];
  }

  function shuffleArray(items) {
    const clone = [...items];
    for (let index = clone.length - 1; index > 0; index -= 1) {
      const swapIndex = Math.floor(Math.random() * (index + 1));
      [clone[index], clone[swapIndex]] = [clone[swapIndex], clone[index]];
    }
    return clone;
  }

  function chunk(items, size) {
    const result = [];
    for (let index = 0; index < items.length; index += size) {
      result.push(items.slice(index, index + size));
    }
    return result;
  }

  function numeric(value, fallback) {
    return Number.isFinite(Number(value)) ? Number(value) : fallback;
  }

  function roundToOne(value) {
    return Math.round(value * 10) / 10;
  }

  function escapeHtml(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;");
  }
})();
