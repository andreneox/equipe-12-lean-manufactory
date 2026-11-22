# Instruções para o Codex — simulador desktop do CLP e gateway da linha

## 1. Objetivo confirmado

Criar aplicação desktop Python/PyQt6 que **substitui o CLP e o gateway do processo**. A tela não é um painel somente de leitura: seus círculos são botões clicáveis que simulam os botões físicos de 12 postos.

Cada ON significa produção parada naquele posto/categoria. Cada OFF encerra essa ocorrência. Usar SQLite local para persistência.

Esta revisão substitui as instruções anteriores que tratavam o mock como coletor OPC UA e servidor TCP. Não misturar esses papéis.

## 2. Componentes e papéis definitivos

| Componente | Papel |
| --- | --- |
| Mock PyQt6 | Simula CLP + gateway: gera estados/eventos, atua como servidor OPC UA e cliente socket TCP. |
| Servidor externo da aplicação/coletor | Cliente OPC UA do mock e servidor TCP receptor dos eventos. |

O mock expõe as 72 variáveis OPC UA e aceita conexões do coletor com certificados. Em paralelo, inicia conexões TCP para entregar eventos ao servidor externo. Não há gateway separado nessa simulação.

Entregar receptor TCP de referência em processo separado, somente para testes, com SQLite próprio. Não iniciá-lo automaticamente no modo normal.

Fluxos: coletor OPC UA → conecta ao servidor OPC UA do mock; mock TCP → conecta ao receptor TCP externo.

## 3. Tela

- Janela PyQt6 nativa, fundo branco, faixa superior azul #1F4E78 e título “Simulador da Linha”.
- Primeira coluna fixa com rótulos; 12 colunas de postos identificados como 01 a 12.
- IDs transmitidos são inteiros 1 a 12. “01” é apenas formatação visual. Por exemplo, posto 12 transmite `00 0C`, não `00 12`.
- Seis linhas: Qualidade, Equipamento, Processo, Material, Takt time e Último ciclo.
- Círculos clicáveis nas quatro linhas Andon. Tempos em caixas com borda azul, uma casa decimal, vírgula e sufixo s.
- Preservar a matriz do mock, com separadores verticais. Em janela pequena, rolar horizontalmente os postos mantendo rótulos visíveis.
- Não adicionar gráficos, relatórios, cadastro ou novos parâmetros industriais.

| Categoria | Cor ON | ID do botão proposto para implementação |
| --- | --- | --- |
| Qualidade | #FFD600 | 1 |
| Equipamento | #5B9BD5 | 2 |
| Processo | #70AD47 | 3 |
| Material | #FF0000 | 4 |

Mapeamento dos botões acima é convenção proposta, configurável para coincidir com o servidor. Os IDs dos postos 1–12 foram confirmados pelo usuário.

OFF: preenchimento #F2F2F2 com borda da categoria. ON: preenchimento sólido. Círculos de 24 px; tooltip com posto/categoria/estado. Não piscar nem emitir sons.

## 4. Clique e estado local

1. Cada clique completo alterna somente a categoria selecionada: OFF → ON ou ON → OFF.
2. Na primeira execução, todas as categorias começam OFF. Nas seguintes, restaurar estados persistidos.
3. No clique, capturar horário uma única vez e montar o evento de 16 bytes.
4. Em uma única transação SQLite local, persistir novo estado e inserir o evento na fila de saída.
5. Após commit, atualizar o círculo imediatamente e acordar o transmissor. A cor representa o estado físico simulado, não a confirmação do servidor.
6. Sem conexão, continuar aceitando cliques e guardando eventos. Nunca descartar ON/OFF intermediários, combinar eventos ou manter apenas o último estado.
7. Se falhar a gravação local, não efetivar a mudança nem mudar a cor; mostrar erro. Não fingir que um evento foi enfileirado.
8. Categorias e postos são independentes; múltiplos ON são permitidos.

O posto está parado enquanto qualquer uma de suas categorias estiver ON. Encerrar uma categoria não significa retomar o posto se outra estiver ativa. Não adicionar indicador visual extra para essa regra.

## 5. Cliente TCP e fila persistente

- O mock é cliente TCP. IP e porta de destino vêm de configuração.
- Uma solicitação por conexão. Apenas um evento industrial em voo por instância do simulador.
- FIFO global: ordenar por ID local autoincremental, criado na transação do clique. Não ordenar pelo timestamp, que pode se repetir ou ser ajustado.
- Enviar o primeiro evento pendente, aguardando confirmação antes de enviar o próximo.
- Timeout inicial configurável: 5 s para conexão, 5 s para envio e 5 s totais para resposta completa. Tratar leituras e envios parciais.
- Receber exatamente 22 bytes para o ACK do Andon e comparar byte a byte com `b"0" * 20 + b"15"`.
- Somente após ACK válido marcar o evento como confirmado em transação local e liberar o próximo. Manter o registro local confirmado para auditoria; não reenviá-lo.
- Em timeout, erro de rede, resposta diferente, resposta parcial ou desconexão antecipada, manter o evento e tentar novamente após 1, 2, 5, 10 e depois 30 segundos, mantendo 30 s nas tentativas seguintes. Não há limite de tentativas.
- Reenviar exatamente os mesmos 16 bytes, inclusive horário. Não gerar um novo evento para representar a tentativa.
- Não saltar um evento que esteja bloqueando a fila e não descartar automaticamente por idade ou quantidade de tentativas.
- Novos cliques entram no fim da fila mesmo durante falha de envio.
- Após reiniciar, retomar o primeiro evento não confirmado. Um evento enviado antes da queda e sem confirmação local persistida continua pendente.
- Falha de configuração/servidor pode bloquear a fila indefinidamente: apresentar diagnóstico técnico discreto, sem fazer descarte automático.
- Retentativa continua enquanto a aplicação estiver aberta; ao fechar, preservar a fila para retomar na próxima execução. Não criar serviço de sistema oculto.

## 6. Protocolo binário

Todas as solicitações mock → servidor possuem **16 bytes**. Campos inteiros de 16 bits são big-endian.

| Offset | Evento Andon |
| --- | --- |
| 0–1 | Tipo 00 01 (evento de Andon) |
| 2–3 | ID posto: inteiro 1–12 |
| 4 | Mês BCD |
| 5 | Ano, dois dígitos finais BCD |
| 6 | Hora BCD |
| 7 | Dia do mês BCD |
| 8 | Segundo BCD |
| 9 | Minuto BCD |
| 10 | Ano, dois primeiros dígitos BCD |
| 11 | Dia da semana BCD: 0 domingo a 6 sábado |
| 12–13 | ID botão |
| 14–15 | Status: 00 01 ON; 00 02 OFF |

Ano = BCD(byte 10) × 100 + BCD(byte 5). Os bytes 10–11 não são contador. Validar calendário e consistência do dia da semana.

Exemplo posto 01, botão 1, segunda-feira 31/08/2026 às 16:08:10, ON:

```text
00 01 00 01 08 26 16 31 10 08 20 01 00 01 00 01
```

OFF 30 segundos depois:

```text
00 01 00 01 08 26 16 31 40 08 20 01 00 01 00 02
```

Resposta Andon: **22 bytes ASCII**, vinte caracteres zero seguidos dos caracteres 1 e 5. Sem quebra de linha ou terminador. Não confundir com zero binário ou 0x15.

## 7. Sincronização do relógio simulado

Pedido de 16 bytes:

```text
00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Resposta de 8 bytes BCD: mês, ano final, hora, dia, segundo, minuto, ano inicial, dia da semana.

Exemplo: `08 26 16 31 58 08 20 01` = 31/08/2026 16:08:58.

Implementar operação de sincronização chamável pelo serviço/configuração, sem botão industrial adicional. Frequência automática permanece pendente de definição. Não inserir solicitações de horário na FIFO de eventos nem permitir que sua falha bloqueie eventos.

Atualizar somente o relógio lógico do simulador, nunca o relógio do sistema operacional. Inicializar o relógio lógico com o horário do computador no fuso IANA configurado; depois de uma resposta válida, avançar com relógio monotônico a partir do horário recebido. Preservar horários dos eventos já enfileirados.

## 8. Servidor OPC UA integrado ao mock

Implementar com `asyncua`, em worker separado da interface. O mock é o servidor, e o coletor externo é o cliente. Não criar um cliente OPC UA no mock para buscar os próprios estados.

Expor exatamente seis variáveis por posto, todas somente leitura para clientes:

| Caminho lógico | Tipo OPC UA | Conteúdo |
| --- | --- | --- |
| P01/Andon/Qualidade | Boolean | Estado local atual de Qualidade. |
| P01/Andon/Equipamento | Boolean | Estado local atual de Equipamento. |
| P01/Andon/Processo | Boolean | Estado local atual de Processo. |
| P01/Andon/Material | Boolean | Estado local atual de Material. |
| P01/TaktTime | Double | Takt em segundos. |
| P01/UltimoCiclo | Double | Último ciclo em segundos. |

Repetir para P01 até P12: 72 variáveis. Namespace URI fixo: `urn:mock-linha:telemetria:v1`. Usar identificadores string estáveis iguais aos caminhos acima, independentemente do índice numérico atribuído ao namespace. Exportar a tabela de NodeIds no README.

O coletor pode ler e assinar mudanças. Escrita remota das variáveis deve ser negada; a aplicação atualiza internamente seus próprios valores.

Após commit do clique, atualizar modelo, tela e valor OPC UA correspondente. O estado exposto é o atual, mesmo que eventos TCP anteriores aguardem confirmação. Falha OPC UA não impede fila TCP nem cliques persistidos. Após reiniciar o serviço OPC UA, publicar novamente todos os estados atuais antes de aceitar clientes.

Não transmitir o pacote TCP de 16 bytes dentro das tags OPC UA. Não transformar leituras/assinaturas OPC UA em novos eventos Andon.

Takt e último ciclo permanecem valores fixos configuráveis nesta versão, sem classificação ou geração automática de ciclos não solicitada.

### Certificados e segurança obrigatórios

- Habilitar exclusivamente endpoint com `SignAndEncrypt`; política definida para esta implementação: `Basic256Sha256`.
- Desabilitar endpoints `None` e somente `Sign`. Não fazer fallback automático para conexão sem segurança.
- O servidor mock usa certificado X.509 próprio e chave privada correspondente, carregados de caminhos configuráveis.
- O coletor usa certificado de aplicação próprio. O mock deve validar a confiança do certificado apresentado pelo cliente; o coletor também deve confiar no certificado do mock.
- Manter lista explícita de certificados de clientes confiáveis. Rejeitar certificados não confiáveis, expirados ou inválidos. Não aceitar automaticamente o primeiro cliente que conectar.
- Validar os campos de identidade exigidos pela biblioteca, inclusive ApplicationUri, e configurar o certificado do servidor para o endereço utilizado pelo coletor.
- Para esta simulação, permitir identidade de usuário Anonymous somente dentro do canal criptografado de um cliente cujo certificado de aplicação foi validado. Anonymous não significa canal sem certificado. Não implementar cadastro de usuários nesta versão.
- Não confundir o certificado da aplicação usado pelo SecureChannel com autenticação de usuário por certificado: esta versão usa o primeiro, com acesso remoto somente leitura.
- Fornecer script separado para gerar certificados de desenvolvimento e instruções de troca/confiança. Nunca gerar, substituir ou confiar certificados silenciosamente ao iniciar.
- Não versionar chaves privadas, imprimir seus conteúdos ou embuti-las no código. Configurar diretórios de certificados e trust list; incluir somente modelos de configuração no repositório.
- Se o certificado do servidor estiver ausente ou inválido, manter OPC UA indisponível com diagnóstico claro. Interface e fila TCP continuam funcionando. Não iniciar endpoint inseguro.
- Certificados definidos aqui se aplicam ao OPC UA. O TCP de eventos mantém o protocolo já acordado, sem inserir TLS ou campos novos silenciosamente.

## 9. Servidor receptor de referência

Processo separado, para validar o comportamento do servidor real:

- Receber 16 bytes completos e identificar tipo 1 ou 2.
- Tipo 1: responder horário atual em 8 bytes BCD, sem ACK Andon.
- Tipo 2: validar, persistir evento e atualizar ocorrência/parada em transação SQLite, depois enviar ACK.
- Banco receptor separado do SQLite do simulador. O ACK exige commit no receptor, não apenas na fila do simulador.
- ON sem ocorrência aberta: abrir com horário do evento.
- OFF com ocorrência aberta e horário válido: fechar; duração em segundos = fim − início.
- Persistir cada recepção, horários original e de recebimento, bytes originais, resultado e vínculo da parada.
- Identificar ocorrência por (posto, botão); permitir uma aberta por chave.
- Para análise futura do tempo parado do posto, considerar união dos intervalos das categorias, nunca soma de intervalos sobrepostos. Não implementar relatório agregado nesta entrega.

Política proposta para exceções: ON enquanto aberto registra ON_REPETIDO sem reiniciar início; OFF sem aberto registra OFF_SEM_ABERTURA; evento anterior à referência de horário já tratada registra ATRASADO sem alterar parada. Todos recebem ACK após commit porque foram tratados. Essa política ainda precisa de confirmação do usuário. Aplicar atraso antes das regras ON/OFF; timestamps iguais seguem ordem de recepção. Persistir referência por chave, atualizando-a em cada evento não atrasado, inclusive repetido/inconsistente.

Erro de banco, formato inválido ou cadastro desconhecido: encerrar sem ACK de sucesso. Não inventar resposta de erro. Serializar transações do receptor para impedir duas aberturas concorrentes.

## 10. Limitação de duplicidade

ID único de posto identifica o local, **não identifica cada evento**. A retentativa da FIFO não elimina o caso em que o servidor salva e a confirmação se perde.

O protocolo atual não contém ID de evento. Não aumentar seus 16 bytes sem autorização. Não prometer registro exatamente uma vez e não deduplicar somente pelos bytes, pois ON/OFF legítimos podem se repetir no mesmo segundo.

A fila ordenada e o tratamento de ON repetido reduzem efeitos, mas não garantem identificação universal de reenvios. Se for obrigatória deduplicação exata, revisar o protocolo com um identificador persistente por evento antes da homologação.

## 11. Estrutura desktop e persistência

- Widgets somente na thread gráfica; rede e SQLite fora dela.
- Signals/slots enfileirados para atualizar estado e diagnósticos.
- Separar interface, modelo de postos, relógio simulado, fila SQLite, cliente TCP, servidor OPC UA e receptor de referência.
- Persistir no simulador: estados locais, fila com bytes imutáveis, ordem local, estado pendente/confirmado, tentativas e último erro.
- Gravar estado e novo evento atomicamente. Usar um worker dono da conexão SQLite, transações e synchronous=FULL.
- Não travar cliques ou redimensionamento enquanto aguarda resposta TCP.
- Encerramento cooperativo: parar novos cliques, concluir transação local, cancelar esperas com prazo e preservar pendências. Não marcar confirmado por simples encerramento.
- Não criar API web, navegador embutido ou dashboard web.

## 12. Entrega e testes

Entregar aplicação PyQt6 executável, configuração de exemplo, dependências fixadas, README e receptor de teste separado. Configuração: postos 1–12, nomes, códigos de botões, destino TCP, fuso IANA, arquivos SQLite e tempos fixos de simulação.

Testar:

1. Primeiro clique gera ON; segundo gera OFF com os 16 bytes corretos.
2. Posto 12 codifica 00 0C.
3. Servidor offline: cliques persistem; cores mudam; fila cresce sem perder transições.
4. Retorno da rede: eventos saem em ordem, um por vez e somente após ACK válido.
5. ACK fragmentado é acumulado; ACK incorreto não libera próximo evento.
6. Reinício mantém estados e fila pendente.
7. Falha de SQLite local impede efetivação do clique.
8. Falha de SQLite receptor impede ACK.
9. ON/OFF do exemplo produzem 30 segundos no receptor.
10. Múltiplas categorias ON podem coexistir; OFF de uma não encerra outra.
11. Pedido de horário tem 16 bytes e resposta tem 8; não altera relógio do computador nem timestamps pendentes.
12. Commit com perda de ACK é testado e a limitação de deduplicação é documentada.

## 13. Decisões ainda necessárias

- Forma de simular/alterar takt e último ciclo além dos valores fixos configurados.
- Frequência da atualização automática do relógio simulado.
- Confirmação dos IDs de botão e política de exceções no receptor.
- Aceitação da limitação de reenvio do protocolo atual ou revisão com ID de evento.

Não apresentar essas decisões como resolvidas pelo ID único dos postos. Implementar completamente a tela, persistência local e envio TCP, incluindo o servidor OPC UA seguro integrado ao próprio mock.

## 14. Organização obrigatória do código Python

Organizar por responsabilidade, com nomes explícitos e dependências simples. Não concentrar interface, protocolo e banco em um único arquivo. Usar type hints, docstrings curtas para regras de negócio e configuração centralizada.

| Módulo/pasta | Responsabilidade exclusiva |
| --- | --- |
| main.py | Entrada; carregar configuração e iniciar aplicação. |
| app/bootstrap.py | Montar dependências, conectar sinais e controlar inicialização/encerramento. |
| config/settings.py | Ler e validar configuração; sem conexão de rede. |
| domain/models.py | Postos, categorias, estado e evento; sem importação de Qt ou rede. |
| domain/clock.py | Relógio lógico da simulação e conversão de horário. |
| services/simulation.py | Receber clique, criar evento e coordenar commit antes de efetivar estado. |
| ui/main_window.py | Janela e composição da matriz. |
| ui/andon_button.py | Aparência e interação do círculo. |
| ui/station_grid.py | Layout dos 12 postos e atualização das células. |
| protocol/tcp_codec.py | Codificação/decodificação pura dos pacotes e ACK, sem sockets. |
| protocol/bcd.py | Conversões BCD e validações de calendário. |
| persistence/database.py | Conexão SQLite, esquema e migrações. |
| persistence/outbox.py | Operações transacionais da fila e estados locais. |
| communications/tcp_sender.py | Cliente TCP, FIFO, timeout, ACK e retentativas. |
| communications/opcua_server.py | Endpoint seguro, criação das 72 tags e atualização interna. |
| security/certificates.py | Carregamento, validação e confiança dos certificados. |
| tools/generate_dev_certificates.py | Geração explícita de certificados de desenvolvimento. |
| tools/reference_receiver.py | Receptor TCP de teste, executável separado. |
| tests/ | Testes de protocolo, persistência, regras, comunicações e interface. |

Widgets emitem intenção de clique; não gravam SQLite nem enviam sockets diretamente. O serviço coordena a transação; após sucesso, distribui a alteração à tela e ao servidor OPC UA. O transmissor consome apenas eventos persistidos da fila.

Uma conexão SQLite pertence ao seu worker. Rede OPC UA e cliente TCP não podem executar operações bloqueantes na thread gráfica. Usar sinais Qt enfileirados para interface e mecanismo thread-safe para atualização no event loop OPC UA. Não chamar métodos asyncua a partir da thread gráfica.

A lógica de domínio e o codec devem ser testáveis sem abrir janela, banco real ou conexão de rede. Evitar variáveis globais mutáveis, imports circulares e caminhos hardcoded. Comentários devem explicar decisões, não repetir cada linha de código.

README deve identificar onde alterar layout, mapeamento de botões, protocolo, retentativas, certificados e tags. Fixar versões das dependências testadas. Entregar configuração de exemplo sem segredos.

## 15. Testes OPC UA e critérios adicionais

- Cliente confiável conecta com SignAndEncrypt/Basic256Sha256, lê as 72 tags e recebe mudanças.
- Certificado de cliente desconhecido ou expirado é rejeitado; endpoint sem segurança não está disponível.
- Certificado do servidor incorreto deve ser rejeitado pelo cliente de teste configurado para validação estrita.
- Tentativa de escrita remota de tag é negada.
- Clique em posto 12 atualiza apenas o estado local, a tag correspondente e insere seu evento TCP na fila.
- Sem coletor OPC UA conectado, cliques e retentativas TCP continuam funcionando.
- Sem receptor TCP, tags OPC UA continuam mostrando o estado atual e a fila persiste.
- Reiniciar restaura estados e fila, recria os mesmos identificadores OPC UA e exige os mesmos certificados configurados.
- Falha no certificado não gera fallback inseguro e não perde eventos.

Se o coletor real não estiver disponível, testar usando cliente OPC UA de teste com certificado próprio e confiança explícita. Informar que esse teste não substitui homologação com o coletor real.
