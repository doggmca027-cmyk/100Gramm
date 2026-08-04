"use client";

import { useState } from "react";
import { markIntroSeen } from "@/lib/api-client";

export function IntroScreen({ onDone }: { onDone: () => void }) {
  const [submitting, setSubmitting] = useState(false);

  async function handleStart() {
    setSubmitting(true);
    try {
      await markIntroSeen();
    } finally {
      onDone();
    }
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-6 overflow-y-auto p-6 text-center">
      <h1 className="text-3xl font-bold">🍾 100ГРАМ</h1>

      <div className="gradient-surface rounded-2xl p-5 text-left text-[15px] leading-relaxed">
        <p>
          Где-то на окраине забытого города открываются твои глаза. Холодный
          асфальт под спиной. Рваная одежда. Пустые карманы. Ни одного
          воспоминания о прошлом.
        </p>
        <p className="mt-3">
          Ты не знаешь, кто ты. Ты не знаешь, как сюда попал. Но ты знаешь
          одно... Тебе нужно выжить.
        </p>
        <p className="mt-4 font-semibold">День 1. Новая жизнь</p>
        <p className="mt-2">
          У тебя нет дома, денег, работы. В этом мире всё имеет цену. Каждая
          бутылка. Каждый грамм. Каждый шанс выбраться наверх.
        </p>
        <p className="mt-3">
          Ты находишь старую бутылку... На ней написано:{" "}
          <span className="font-semibold text-gram">1 GRAM</span>. Говорят,
          тот, кто соберёт достаточно GRAM, сможет изменить свою судьбу.
        </p>
        <ul className="mt-4 space-y-1">
          <li>🥃 Собирай первые граммы</li>
          <li>⏳ Запускай циклы добычи</li>
          <li>💰 Увеличивай свои запасы</li>
          <li>🔓 Открывай новые возможности</li>
          <li>🏚️ Поднимайся от улицы до богатства</li>
        </ul>
        <p className="mt-4">
          Сегодня ты всего лишь бомж без гроша в кармане. Но завтра ты можешь
          стать легендой мира 100ГРАМ.
        </p>
      </div>

      <button
        type="button"
        onClick={handleStart}
        disabled={submitting}
        className="gradient-action mt-auto rounded-full px-6 py-4 text-lg font-bold disabled:opacity-60"
      >
        🚀 НАЧАТЬ ПУТЬ
      </button>
    </div>
  );
}
