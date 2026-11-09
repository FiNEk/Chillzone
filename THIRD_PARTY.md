# Сторонний код

## Olympus

Часть кода Chillzone (кодек отчётов, очистка и нарезка строк чата, сборка
кусков сообщений, работа с именами WoW: Forever, ретрансляция шёпотом,
скрытие канала, круги на карте) портирована из аддона Olympus 1.5.0:
<https://github.com/dnl-gentile/olympus-addon>

Поиск для вступления, адресные заявки, подсказки маршрута и действия получателя
адаптированы из `Who.lua` и `Recruit.lua`, коммит
`c1064682a74396be4904040b6ee709187019861a` (MIT). В Chillzone интерфейс,
проверки ростера, работа с именами и транспорт используют местные модули.

```
MIT License

Copyright (c) Olympus addon contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Библиотеки в `Chillzone/libs`

`Ed25519.lua` и тестовые векторы взяты без изменений из Olympus,
коммит `ed7a81e2af029f74818eadac8e062c4b585989be`.
Это реализация Ed25519/SHA-512 для Lua 5.1 с разбиением работы по кадрам;
арифметика основана на TweetNaCl. MIT-лицензия сохранена отдельно в
`Chillzone/libs/LICENSE-Ed25519.txt`. Генератор исходного секрета в
`Security.lua` повторяет подход `Sign.EntropySample`/`Debts.Entropy` Olympus;
криптографически стойкий источник случайности внутри игры не гарантируется.

| Библиотека | Версия | Лицензия |
|---|---|---|
| LibStub | — | общественное достояние (public domain) |
| CallbackHandler-1.0 | r8 | BSD-подобная лицензия Ace3, см. `libs/CallbackHandler-1.0/LICENSE-Ace3.txt` |
| LibDataBroker-1.1 | minor 4 | All Rights Reserved; автор разрешает включение в аддоны, см. ссылку ниже |
| LibDBIcon-1.0 | minor 57, SVN r165 | Ace3 Style BSD на странице проекта, см. `libs/LibDBIcon-1.0/LICENSE-Ace3.txt` |
| HereBeDragons-2.0 | r33 | BSD (`X-License` в `HereBeDragons.toc` автора, Nevcairiel), см. <https://github.com/Nevcairiel/HereBeDragons> |
| HereBeDragons-Pins-2.0 | r17 | то же |

LibDataBroker взят без изменений из <https://github.com/tekkub/libdatabroker-1-1>,
коммит `1a63ede0248c11aa1ee415187c1f9c9489ce3e02`.
Условия и указание автора включать библиотеку непосредственно в аддон:
<https://www.wowace.com/projects/libdatabroker-1-1>.

LibDBIcon взят без изменений из официального SVN, ревизия 165:
<https://repos.wowace.com/wow/libdbicon-1-0/!svn/bc/165/trunk/LibDBIcon-1.0/LibDBIcon-1.0.lua>.
Лицензия на странице проекта: <https://www.wowace.com/project/15552/license>.
В toc автора указано All Rights Reserved; отдельно на странице проекта опубликована
Ace3 Style BSD и прямо предусмотрено включение библиотеки в аддоны:
<https://www.wowace.com/projects/libdbicon-1-0>.
