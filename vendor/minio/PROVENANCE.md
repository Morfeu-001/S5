# MinIO Dart 3.5.0: fonte fixada sem atualização

Fonte original: `redsolver/minio-dart`, commit
`c0ddd199a4edabb0fa78d553a89b08944fc1c137`, árvore
`9af9f129fb0f013ab4018160d67a57912c82b133`.

Esse commit continua acessível pelo arquivo/API do GitHub, mas não aparece no
clone mirror das refs anunciadas pelo repositório. Dart 3.3.1 falhou ao resolver
o mesmo lockfile em cache limpo; a instalação anterior conservava esse checkout.
Não substituir pelo HEAD 3.5.7 nem atualizar dependências implicitamente.

`lib/`, `pubspec.yaml`, `LICENSE` e `README.md` são cópias sem alteração da árvore
original. Cada arquivo foi conferido contra seu Git blob SHA-1 da API oficial.
SHA-256 do tarball recebido em 30/09/2026:
`c81ba116b326de589bef70b9dbe0ee5df925c10a6d356ee03dfc2c28e5f0bded`.

A versão permanece 3.5.0, com sua licença MIT e constraints originais.
`pubspec_overrides.yaml` seleciona esta fonte local para permitir instalação
reproduzível; nenhuma lógica MinIO foi editada.
