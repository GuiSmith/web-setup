# Desafio Final NET {EVOLUTION}

Este repositório contém um script em **Shell** para instalação e configuração automatizada do **Nginx**, **PHP-FPM** e **MariaDB**.

O script realiza as seguintes etapas:
- Validação de erros de configuração antes de recarregar os serviços.
- Inclusão de arquivos personalizados de configuração diretamente via script.
- Criação de um usuário com senha no banco de dados.
- Detecção automática de arquivo `.sql` no diretório de execução e importação dos dados, se disponível.
- Documentação clara no código, descrevendo cada etapa da execução.

## Observações importantes
- **Compatibilidade:** o script foi testado no **Debian 12** e no **Ubuntu**. No Ubuntu ocorreram erros, portanto o script foi ajustado e desenvolvido **exclusivamente para rodar no Debian 12**.
- **Ambiente de testes:** a máquina virtual utilizada para desenvolvimento foi criada no **Virt-Manager**.
- **Requisitos mínimos da VM:** 1 processador e 2 GB de memória RAM.

Além disso, é possível recriar o ambiente utilizado nas aulas do **ControleVM**, utilizando um **dump** do banco de dados (`.sql`) ou adicionando a estrutura padrão de forma automática.
