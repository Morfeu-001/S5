# S5 clássico: provider M2 e recuperação de conexões

Derivado de S5 v0.14.1, base `7b9fc6def87644c66c33274f9a6b217a29231efd`.
Não é uma release oficial upstream. `vendor/lib5` conserva a licença original
e a proveniência do pacote 0.2.0 registrada em `PATCH-NOTES.md`; os Git refs e
versões do lockfile são fixados. MinIO 3.5.0 também está em `vendor/minio`, sem
alteração de código: seu commit histórico não aparece mais nas refs clonadas
pelo mirror do Dart. A instalação limpa reproduziu a falha e passou após usar
os mesmos arquivos originais, conferidos por Git blob SHA-1. Nenhuma versão de
dependência foi atualizada. Nenhuma identidade privada entra no repositório.

## Problema observado em 30/09/2026

O serviço do piloto permaneceu active, mas o cliente não descobriu os oito
CIDs por sfive/garden nem diretamente pelo publicador. O processo tinha centenas
de TCPs estabelecidos. Reiniciar somente o serviço recuperou a consulta direta;
os hashes da configuração e dos três crons continuaram idênticos. Os peers
externos continuaram sem fontes nessa rodada. Isso não prova a causa interna
dos relays externos nem que eles executam esta versão.

O receiver valida assinaturas e recusa anúncios vencidos. Porém uma exceção de
callback escapava para a zona de conexão e disparava outro socket sem encerrar
o anterior. O fechamento de uma instância antiga também removia a nova do mapa
por compartilhar o ID. Uma consulta sem resposta conservava sua rota para
sempre, impedindo novo encaminhamento após recuperação de um provider.

## Correção

- Mensagens recusadas depois da autenticação ficam contidas no listener.
- Handshake recusado ou silencioso por dez segundos encerra o lifetime e o
  socket. Features e URIs são validadas antes de publicar o peer conectado.
- Uma tentativa por NodeID, fechamento idempotente da subscription/socket antes
  do retry e backoff limitado a sessenta segundos.
- `onDone` e `onError` retiram a mesma instância, preservando eventual substituta.
- Rotas pendentes expiram por relógio monotônico em trinta segundos; limpeza por
  consulta, no máximo 4.096 hashes e 64 interessados por hash.
- A resposta de uma localização própria demandada é compartilhada com relays
  conectados. Só esse CID é anunciado; não há varredura nem anúncio periódico
  de todo o inventário. Localizações de outro provider não são reanunciadas.

O store remoto continua somente leitura e responde pelo índice exato
CID/tamanho/URL, cujos bytes o operador já verificou. Cadastrar metadados não
cria uma cópia nem verifica novamente os bytes do endpoint remoto.

## Validação

Linux Dart 3.3.1, workspace de build isolado: 36 testes passaram, incluindo nove
de lifecycle e os 26 de assinatura/store. Análise dos arquivos alterados limpa.
RED reproduziu exceção escapada, remoção da substituta, consulta que não volta
a ser encaminhada e ausência de anúncio aos relays. Os casos posteriores de
handshake recusado e erro de transporte sem onDone têm regressões específicas.
O socket recebido também foi ensaiado com HTTP/WebSocket real em loopback.
Uma regressão adicional usa Hive nativo descartável: o anúncio próprio fica
visível imediatamente e permanece íntegro após fechar/reabrir o banco.
Vários `[providing]` concorrentes não provaram falha de persistência local.
Não representa duas infraestruturas independentes nem APK físico.

```sh
dart pub get --enforce-lockfile
dart test -r expanded
dart analyze lib/store/remote_locations.dart lib/service/p2p.dart test/p2p_lifecycle_test.dart vendor/lib5/lib/src/node/service/p2p.dart
dart compile aot-snapshot bin/s5_server.dart -o s5_server.aot
```

O AOT requer o dartaotruntime compatível e as bibliotecas nativas da instalação.
Não substituir binário/configuração do serviço em execução sem guardar a
release anterior, validar os hashes e preparar rollback do ponteiro. Preservar
identidade, índice, bytes, crons e banco do aplicativo. O arquivo AOT do CI é
artefato de build, não prova de implantação.

## Aceites ainda dependentes de ambiente

Autonomia depois do TTL exige outros providers com identidade e índice próprios.
Dois subdomínios/hosts do mesmo operador não provam falhas independentes.
O app deve continuar verificando localização assinada e todos os bytes antes
de exibir. Habilitar apenas o piloto cujas fontes reais estejam disponíveis.

## Implantação e prova de rede de 30/09/2026

O código de runtime `45d3ece5bbb51b1d0c73f9470081bad4fced5b15` foi conferido
contra 135 arquivos do workspace Linux. Build limpo com PUB_CACHE vazio e
runtime ativo têm SHA-256 AOT
`4e296d131e8024b7169a57ab127ccd4ce0a1d540360f7f66ce68f2ef4be10f48`.
Release ativa `/opt/manhastro-s5/releases/0.14.1-signature3-lifecycle`, anterior
preservada; configuração/identidade, oito registros de índice e crons têm
os mesmos hashes anteriores. Somente o serviço S5 foi reiniciado; não houve
catálogo/bucket/DNS/backfill/cron novo. Manifest de ativação e de rebuild
ficam privados no host, sem material secreto no PR.

O cliente Chrome recebeu 8/8 páginas reais Wasabi, por sfive/garden, com
2.938.551 bytes conferidos por CID e decodificação AVIF, sem conectar ao Albums
nem descoberta HTTP editorial. O provider Albums ficou online. Repetições
após TTL encontraram anúncios vencidos nos relays, provocando indisponibilidade
explícita; o reader recebeu correções de orçamento/retry no
[PR site-mobile #111](https://github.com/Morfeu-001/site-mobile/pull/111).
A evidência e todos os limites atuais ficam no
[relatório de entrega](https://github.com/Morfeu-001/site-mobile/blob/codex/reader-native-s5/docs/testing/cid-reader/2026-09-30-m2-delivery.md).
Isso não declara autonomia ou confiabilidade de relays públicos fora de nossa
operação. São necessários providers/operadores independentes para o aceite.
