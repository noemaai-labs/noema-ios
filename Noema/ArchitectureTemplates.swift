import Foundation
import NoemaPackages

/// Curated Jinja chat templates for specific model architectures.
/// These are prioritized for GGUF, MLX, and CML text models; if none match, we fall back
/// to existing config/tokenizer/GGUF metadata or family heuristics.
enum ArchitectureTemplates {
    /// Returns a curated Jinja chat template string for the given local model
    /// when the format is GGUF, MLX, or CML. Returns nil when no curated mapping applies.
    static func template(for model: LocalModel) -> String? {
        let format = model.format
        guard format == .gguf || format == .mlx || format == .ane else { return nil }
        // Use the best-guess identifier based on file/folder name
        let ident = model.url.deletingPathExtension().lastPathComponent.lowercased()

        // DeepSeek R1 Distill on Qwen: prefer tokenizer-driven DeepSeek markers and
        // this specialized template when the model name clearly indicates the combo.
        if ident.contains("deepseek") && ident.contains("distill") && ident.contains("qwen") {
            return Templates.deepseekR1DistillOnQwen
        }

        // DeepSeek R1 Distill on Llama: use DeepSeek markers with Llama-style generation prompt
        if ident.contains("deepseek") && ident.contains("distill") && ident.contains("llama") {
            return Templates.deepseekR1DistillOnLlama
        }

        if TemplateDrivenModelSupport.isQwen35(modelID: model.modelID, modelURL: model.url) {
            return nil
        }

        // Qwen3 family
        if ident.contains("qwen3") || ident.contains("qwen-3") || ident.contains("qwen 3") || ident.contains("qwen3n") {
            return Templates.qwen3
        }

        // Liquid LFM (LFM2)
        if ident.contains("lfm2") || ident.contains("liquid") {
            return Templates.lfm2
        }

        // Granite Hybrid / IBM Granite
        if ident.contains("granitehybrid") || ident.contains("granite-hybrid") || ident.contains("granite") {
            return Templates.graniteHybrid
        }

        // Gemma 3n vs Gemma 3
        if ident.contains("gemma-3n") || ident.contains("gemma3n") {
            return Templates.gemma3n
        }
        if ident.contains("gemma-3") || ident.contains("gemma3") {
            return Templates.gemma3
        }

        // Llama family (prefer Llama 3 style when unknown)
        if ident.contains("llama") {
            return Templates.llama
        }

        // Phi-3 family
        if ident.contains("phi-3") || ident.contains("phi3") {
            return Templates.phi3
        }

        return nil
    }

    enum Templates {
        static let deepseekR1DistillOnLlama: String = """
{% if not add_generation_prompt is defined %}{% set add_generation_prompt = false %}{% endif %}{% set ns = namespace(is_first=false, is_tool=false, is_output_first=true, system_prompt='') %}{%- for message in messages %}{%- if message['role'] == 'system' %}{% set ns.system_prompt = message['content'] %}{%- endif %}{%- endfor %}{{bos_token}}{{ns.system_prompt}}{%- for message in messages %}{%- if message['role'] == 'user' %}{%- set ns.is_tool = false -%}{{'<｜User｜>' + message['content']}}{%- endif %}{%- if message['role'] == 'assistant' and message['content'] is none %}{%- set ns.is_tool = false -%}{%- for tool in message['tool_calls']%}{%- if not ns.is_first %}{{'<｜Assistant｜><｜tool▁calls▁begin｜><｜tool▁call▁begin｜>' + tool['type'] + '<｜tool▁sep｜>' + tool['function']['name'] + '\n' + '```json' + '\n' + (tool['function']['arguments'] if tool['function']['arguments'] is string else tool['function']['arguments'] | tojson) + '\n' + '```' + '<｜tool▁call▁end｜>'}}{%- set ns.is_first = true -%}{%- else %}{{'\n' + '<｜tool▁call▁begin｜>' + tool['type'] + '<｜tool▁sep｜>' + tool['function']['name'] + '\n' + '```json' + '\n' + (tool['function']['arguments'] if tool['function']['arguments'] is string else tool['function']['arguments'] | tojson) + '\n' + '```' + '<｜tool▁call▁end｜>'}}{{'<｜tool▁calls▁end｜><｜end▁of▁sentence｜>'}}{%- endif %}{%- endfor %}{%- endif %}{%- if message['role'] == 'assistant' and message['content'] is not none %}{%- if ns.is_tool %}{{'<｜tool▁outputs▁end｜>' + message['content'] + '<｜end▁of▁sentence｜>'}}{%- set ns.is_tool = false -%}{%- else %}{% set content = message['content'] %}{% if '</think>' in content %}{% set content = content.split('</think>')[-1] %}{% endif %}{{'<｜Assistant｜>' + content + '<｜end▁of▁sentence｜>'}}{%- endif %}{%- endif %}{%- if message['role'] == 'tool' %}{%- set ns.is_tool = true -%}{%- if ns.is_output_first %}{{'<｜tool▁outputs▁begin｜><｜tool▁output▁begin｜>' + message['content'] + '<｜tool▁output▁end｜>'}}{%- set ns.is_output_first = false %}{%- else %}{{'\n<｜tool▁output▁begin｜>' + message['content'] + '<｜tool▁output▁end｜>'}}{%- endif %}{%- endif %}{%- endfor -%}{% if ns.is_tool %}{{'<｜tool▁outputs▁end｜>'}}{% endif %}{% if add_generation_prompt and not ns.is_tool %}{{'<｜Assistant｜><think>\n'}}{% endif %}
"""
        static let deepseekR1DistillOnQwen: String = """
{% if not add_generation_prompt is defined %}{% set add_generation_prompt = false %}{% endif %}{% set ns = namespace(is_first=false, is_tool=false, is_output_first=true, system_prompt='', is_first_sp=true, is_last_user=false) %}{%- for message in messages %}{%- if message['role'] == 'system' %}{%- if ns.is_first_sp %}{% set ns.system_prompt = ns.system_prompt + message['content'] %}{% set ns.is_first_sp = false %}{%- else %}{% set ns.system_prompt = ns.system_prompt + '\n\n' + message['content'] %}{%- endif %}{%- endif %}{%- endfor %}{{ bos_token }}{{ ns.system_prompt }}{%- for message in messages %}{% set content = message['content'] %}{%- if message['role'] == 'user' %}{%- set ns.is_tool = false -%}{%- set ns.is_first = false -%}{%- set ns.is_last_user = true -%}{{'<｜User｜>' + content + '<｜Assistant｜>'}}{%- endif %}{%- if message['role'] == 'assistant' %}{% if '</think>' in content %}{% set content = content.split('</think>')[-1] %}{% endif %}{% endif %}{%- if message['role'] == 'assistant' and message['tool_calls'] is defined and message['tool_calls'] is not none %}{%- set ns.is_last_user = false -%}{%- if ns.is_tool %}{{'<｜tool▁outputs▁end｜>'}}{%- endif %}{%- set ns.is_first = false %}{%- set ns.is_tool = false -%}{%- set ns.is_output_first = true %}{%- for tool in message['tool_calls'] %}{%- if not ns.is_first %}{%- if content is none %}{{'<｜tool▁calls▁begin｜><｜tool▁call▁begin｜>' + tool['type'] + '<｜tool▁sep｜>' + tool['function']['name'] + '\n' + '```json' + '\n' + (tool['function']['arguments'] if tool['function']['arguments'] is string else tool['function']['arguments'] | tojson) + '\n' + '```' + '<｜tool▁call▁end｜>'}}{%- else %}{{content + '<｜tool▁calls▁begin｜><｜tool▁call▁begin｜>' + tool['type'] + '<｜tool▁sep｜>' + tool['function']['name'] + '\n' + '```json' + '\n' + (tool['function']['arguments'] if tool['function']['arguments'] is string else tool['function']['arguments'] | tojson) + '\n' + '```' + '<｜tool▁call▁end｜>'}}{%- endif %}{%- set ns.is_first = true -%}{%- else %}{{'\n' + '<｜tool▁call▁begin｜>' + tool['type'] + '<｜tool▁sep｜>' + tool['function']['name'] + '\n' + '```json' + '\n' + (tool['function']['arguments'] if tool['function']['arguments'] is string else tool['function']['arguments'] | tojson) + '\n' + '```' + '<｜tool▁call▁end｜>'}}{%- endif %}{%- endfor %}{{'<｜tool▁calls▁end｜><｜end▁of▁sentence｜>'}}{%- endif %}{%- if message['role'] == 'assistant' and (message['tool_calls'] is not defined or message['tool_calls'] is none)%}{%- set ns.is_last_user = false -%}{%- if ns.is_tool %}{{'<｜tool▁outputs▁end｜>' + content + '<｜end▁of▁sentence｜>'}}{%- set ns.is_tool = false -%}{%- else %}{{content + '<｜end▁of▁sentence｜>'}}{%- endif %}{%- endif %}{%- if message['role'] == 'tool' %}{%- set ns.is_last_user = false -%}{%- set ns.is_tool = true -%}{%- if ns.is_output_first %}{{'<｜tool▁outputs▁begin｜><｜tool▁output▁begin｜>' + content + '<｜tool▁output▁end｜>'}}{%- set ns.is_output_first = false %}{%- else %}{{'\n<｜tool▁output▁begin｜>' + content + '<｜tool▁output▁end｜>'}}{%- endif %}{%- endif %}{%- endfor -%}{% if ns.is_tool %}{{'<｜tool▁outputs▁end｜>'}}{% endif %}{% if add_generation_prompt and not ns.is_last_user and not ns.is_tool %}{{'<｜Assistant｜>'}}{% endif %}
"""
        static let qwen3: String = """
Qwen3:{%- if tools %}
    {{- '<|im_start|>system\n' }}
    {%- if messages[0].role == 'system' %}
        {{- messages[0].content + '\n\n' }}
    {%- endif %}
    {{- "# Tools\n\nYou may call one or more functions to assist with the user query.\n\nYou are provided with function signatures within <tools></tools> XML tags:\n<tools>" }}
    {%- for tool in tools %}
        {{- "\n" }}
        {{- tool | tojson }}
    {%- endfor %}
    {{- "\n</tools>\n\nFor each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:\n<tool_call>\n{\"name\": <function-name>, \"arguments\": <args-json-object>}\n</tool_call><|im_end|>\n" }}
{%- else %}
    {%- if messages[0].role == 'system' %}
        {{- '<|im_start|>system\n' + messages[0].content + '<|im_end|>\n' }}
    {%- endif %}
{%- endif %}
{%- set ns = namespace(multi_step_tool=true, last_query_index=messages|length - 1) %}
{%- for message in messages[::-1] %}
    {%- set index = (messages|length - 1) - loop.index0 %}
    {%- if ns.multi_step_tool and message.role == "user" and message.content is string and not(message.content.startswith('<tool_response>') and message.content.endswith('</tool_response>')) %}
        {%- set ns.multi_step_tool = false %}
        {%- set ns.last_query_index = index %}
    {%- endif %}
{%- endfor %}
{%- for message in messages %}
    {%- if message.content is string %}
        {%- set content = message.content %}
    {%- else %}
        {%- set content = '' %}
    {%- endif %}
    {%- if (message.role == "user") or (message.role == "system" and not loop.first) %}
        {{- '<|im_start|>' + message.role + '\n' + content + '<|im_end|>' + '\n' }}
    {%- elif message.role == "assistant" %}
        {%- set reasoning_content = '' %}
        {%- if message.reasoning_content is string %}
            {%- set reasoning_content = message.reasoning_content %}
        {%- else %}
            {%- if '</think>' in content %}
                {%- set reasoning_content = content.split('</think>')[0].rstrip('\n').split('<think>')[-1].lstrip('\n') %}
                {%- set content = content.split('</think>')[-1].lstrip('\n') %}
            {%- endif %}
        {%- endif %}
        {%- if loop.index0 > ns.last_query_index %}
            {%- if loop.last or (not loop.last and reasoning_content) %}
                {{- '<|im_start|>' + message.role + '\n<think>\n' + reasoning_content.strip('\n') + '\n</think>\n\n' + content.lstrip('\n') }}
            {%- else %}
                {{- '<|im_start|>' + message.role + '\n' + content }}
            {%- endif %}
        {%- else %}
            {{- '<|im_start|>' + message.role + '\n' + content }}
        {%- endif %}
        {%- if message.tool_calls %}
            {%- for tool_call in message.tool_calls %}
                {%- if (loop.first and content) or (not loop.first) %}
                    {{- '\n' }}
                {%- endif %}
                {%- if tool_call.function %}
                    {%- set tool_call = tool_call.function %}
                {%- endif %}
                {{- '<tool_call>\n{"name": "' }}
                {{- tool_call.name }}
                {{- '", "arguments": ' }}
                {%- if tool_call.arguments is string %}
                    {{- tool_call.arguments }}
                {%- else %}
                    {{- tool_call.arguments | tojson }}
                {%- endif %}
                {{- '}\n</tool_call>' }}
            {%- endfor %}
        {%- endif %}
        {{- '<|im_end|>\n' }}
    {%- elif message.role == "tool" %}
        {%- if loop.first or (messages[loop.index0 - 1].role != "tool") %}
            {{- '<|im_start|>user' }}
        {%- endif %}
        {{- '\n<tool_response>\n' }}
        {{- content }}
        {{- '\n</tool_response>' }}
        {%- if loop.last or (messages[loop.index0 + 1].role != "tool") %}
            {{- '<|im_end|>\n' }}
        {%- endif %}
    {%- endif %}
{%- endfor %}
{%- if add_generation_prompt %}
    {{- '<|im_start|>assistant\n' }}
{%- endif %}
"""

        static let lfm2: String = """
LFM2: {{bos_token}}{% for message in messages %}{{'<|im_start|>' + message['role'] + '\n' + message['content'] + '<|im_end|>' + '\n'}}{% endfor %}{% if add_generation_prompt %}{{ '<|im_start|>assistant\n' }}{% endif %}
"""

        static let graniteHybrid: String = """
{%- set tools_system_message_prefix = 'You are a helpful assistant with access to the following tools. You may call one or more tools to assist with the user query.\n\nYou are provided with function signatures within <tools></tools> XML tags:\n<tools>'  %}
{%- set tools_system_message_suffix = '\n</tools>\n\nFor each tool call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:\n<tool_call>\n{"name": <function-name>, "arguments": <args-json-object>}\n</tool_call>.\n\n## How to call tools:\nWhen you call a tool call, the value of "arguments" must be a valid, parsed JSON object. It must NEVER be stringified JSON. Do NOT EVER escape JSON yourself. Always provide raw, valid JSON.\n\nIf a tool does not exist in the provided list of tools, notify the user that you do not have the ability to fulfill the request.\n\nFor example, your tool call SHOULD look like this\n<tool_call>\n{"name": "get_current_weather", "arguments": {"city": "Boston"}}\n</tool_call>\n\nIt should NEVER look like this\n<tool_call>\n{"name": "get_current_weather", "arguments": "{\n  \"city\": \"Boston\"\n}"}\n</tool_call>' %}
{%- set documents_system_message_prefix = 'You are a helpful assistant with access to the following documents. You may use one or more documents to assist with the user query.\n\nYou are given a list of documents within <documents></documents> XML tags:\n<documents>' %}
{%- set documents_system_message_suffix = '\n</documents>\n\nWrite the response to the user\'s input by strictly aligning with the facts in the provided documents. If the information needed to answer the question is not available in the documents, inform the user that the question cannot be answered based on the available data.' %}
{%- if available_tools is defined and available_tools %}
    {%- set tools = available_tools %}
{%- endif %}
{%- set ns = namespace(tools_system_message=tools_system_message_prefix,
                      documents_system_message=documents_system_message_prefix,
                      system_message=''
                      ) %}
{%- if tools %}
    {%- for tool in tools %}
        {%- set ns.tools_system_message = ns.tools_system_message + '\n' + (tool | tojson) %}
    {%- endfor %}
    {%- set ns.tools_system_message = ns.tools_system_message + tools_system_message_suffix %}
{%- else %}
    {%- set ns.tools_system_message = '' %}
{%- endif %}
{%- if documents %}
    {%- for document in documents %}
        {%- set ns.documents_system_message = ns.documents_system_message + '\n' + (document | tojson) %}
    {%- endfor %}
    {%- set ns.documents_system_message = ns.documents_system_message + documents_system_message_suffix %}
{%- else %}
    {%- set ns.documents_system_message = '' %}
{%- endif %}
{%- if messages[0].role == 'system' %}
    {%- if messages[0].content is string %}
        {%- set ns.system_message = messages[0].content %}
    {%- elif messages[0].content is iterable %}
        {%- for entry in messages[0].content %}
            {%- if entry.type== 'text' %}
                {%- if ns.system_message != '' %}
                    {%- set ns.system_message = ns.system_message + '\n' %}
                {%- endif %}
                {%- set ns.system_message = ns.system_message + entry.text %}
            {%- endif %}
        {%- endfor %}
    {%- endif %}
    {%- if tools and documents %}
        {%- set ns.system_message = ns.system_message + '\n\n' +  ns.tools_system_message + '\n\n' + ns.documents_system_message %}
    {%- elif tools %}
        {%- set ns.system_message = ns.system_message + '\n\n' + ns.tools_system_message %}
    {%- elif documents %}
        {%- set ns.system_message = ns.system_message + '\n\n' + ns.documents_system_message %}
    {%- endif %}
{%- else %}
    {%- if tools and documents %}
        {%- set ns.system_message = ns.tools_system_message + '\n\n' + ns.documents_system_message  %}
    {%- elif tools %}
        {%- set ns.system_message = ns.tools_system_message %}
    {%- elif documents %}
        {%- set ns.system_message = ns.documents_system_message %}
    {%- endif %}
{%- endif %}
{%- if ns.system_message %}
    {{- '<|start_of_role|>system<|end_of_role|>' + ns.system_message + '<|end_of_text|>\n' }}
{%- endif %}
{%- for message in messages %}
    {%- set content = namespace(val='') %}
    {%- if message.content is string %}
        {%- set content.val = message.content %}
    {%- else %}
        {%- if message.content is iterable %}
            {%- for entry in message.content %}
                {%- if entry.type== 'text' %}
                    {%- if content.val != '' %}
                        {%- set content.val = content.val + '\n' %}
                    {%- endif %}
                    {%- set content.val = content.val + entry.text %}
                {%- endif %}
            {%- endfor %}
        {%- endif %}
    {%- endif %}
    {%- if (message.role == 'user') or (message.role == 'system' and not loop.first) %}
        {{- '<|start_of_role|>' + message.role + '<|end_of_role|>' + content.val + '<|end_of_text|>\n' }}
    {%- elif message.role == 'assistant' %}
        {{- '<|start_of_role|>' + message.role + '<|end_of_role|>' + content.val }}
        {%- if message.tool_calls %}
            {%- for tool_call in message.tool_calls %}
                {%- if (loop.first and content.val) or (not loop.first) %}
                    {{- '\n' }}
                {%- endif %}
                {%- if tool_call.function %}
                    {%- set tool_call = tool_call.function %}
                {%- endif %}
                {{- '<tool_call>\n{"name": "' }}
                {{- tool_call.name }}
                {{- '", "arguments": ' }}
                {%- if tool_call.arguments is string %}
                    {{- tool_call.arguments }}
                {%- else %}
                    {{- tool_call.arguments | tojson }}
                {%- endif %}
                {{- '}\n</tool_call>' }}
            {%- endfor %}
        {%- endif %}
        {{- '<|end_of_text|>\n' }}
    {%- elif message.role == 'tool' %}
        {%- if loop.first or (messages[loop.index0 - 1].role != 'tool') %}
            {{- '<|start_of_role|>user<|end_of_role|>' }}
        {%- endif %}
        {{- '\n<tool_response>\n' }}
        {{- content.val }}
        {{- '\n</tool_response>' }}
        {%- if loop.last or (messages[loop.index0 + 1].role != 'tool') %}
            {{- '<|end_of_text|>\n' }}
        {%- endif %}
    {%- endif %}
{%- endfor %}
{%- if add_generation_prompt %}
    {{- '<|start_of_role|>assistant<|end_of_role|>' }}
{%- endif %}
"""

        static let gemma3n: String = """
{{ bos_token }}
{%- if messages[0]['role'] == 'system' -%}
    {%- if messages[0]['content'] is string -%}
        {%- set first_user_prefix = messages[0]['content'] + '\n\n' -%}
    {%- else -%}
        {%- set first_user_prefix = messages[0]['content'][0]['text'] + '\n\n' -%}
    {%- endif -%}
    {%- set loop_messages = messages[1:] -%}
{%- else -%}
    {%- set first_user_prefix = "" -%}
    {%- set loop_messages = messages -%}
{%- endif -%}
{%- for message in loop_messages -%}
    {%- if (message['role'] == 'user') != (loop.index0 % 2 == 0) -%}
        {{ raise_exception("Conversation roles must alternate user/assistant/user/assistant/...") }}
    {%- endif -%}
    {%- if (message['role'] == 'assistant') -%}
        {%- set role = "model" -%}
    {%- else -%}
        {%- set role = message['role'] -%}
    {%- endif -%}
    {{ '<start_of_turn>' + role + '\n' + (first_user_prefix if loop.first else "") }}
    {%- if message['content'] is string -%}
        {{ message['content'] | trim }}
    {%- elif message['content'] is iterable -%}
        {%- for item in message['content'] -%}
            {%- if item['type'] == 'audio' -%}
                {{ '<audio_soft_token>' }}
            {%- elif item['type'] == 'image' -%}
                {{ '<image_soft_token>' }}
            {%- elif item['type'] == 'text' -%}
                {{ item['text'] | trim }}
            {%- endif -%}
        {%- endfor -%}
    {%- else -%}
        {{ raise_exception("Invalid content type") }}
    {%- endif -%}
    {{ '<end_of_turn>\n' }}
{%- endfor -%}
{%- if add_generation_prompt -%}
    {{'<start_of_turn>model\n'}}
{%- endif -%}
"""

        static let gemma3: String = """
{{ bos_token }}
{%- if messages[0]['role'] == 'system' -%}
    {%- if messages[0]['content'] is string -%}
        {%- set first_user_prefix = messages[0]['content'] + '\n\n' -%}
    {%- else -%}
        {%- set first_user_prefix = messages[0]['content'][0]['text'] + '\n\n' -%}
    {%- endif -%}
    {%- set loop_messages = messages[1:] -%}
{%- else -%}
    {%- set first_user_prefix = "" -%}
    {%- set loop_messages = messages -%}
{%- endif -%}
{%- for message in loop_messages -%}
    {%- if (message['role'] == 'user') != (loop.index0 % 2 == 0) -%}
        {{ raise_exception("Conversation roles must alternate user/assistant/user/assistant/...") }}
    {%- endif -%}
    {%- if (message['role'] == 'assistant') -%}
        {%- set role = "model" -%}
    {%- else -%}
        {%- set role = message['role'] -%}
    {%- endif -%}
    {{ '<start_of_turn>' + role + '\n' + (first_user_prefix if loop.first else "") }}
    {%- if message['content'] is string -%}
        {{ message['content'] | trim }}
    {%- elif message['content'] is iterable -%}
        {%- for item in message['content'] -%}
            {%- if item['type'] == 'image' -%}
                {{ '<start_of_image>' }}
            {%- elif item['type'] == 'text' -%}
                {{ item['text'] | trim }}
            {%- endif -%}
        {%- endfor -%}
    {%- else -%}
        {{ raise_exception("Invalid content type") }}
    {%- endif -%}
    {{ '<end_of_turn>\n' }}
{%- endfor -%}
{%- if add_generation_prompt -%}
    {{'<start_of_turn>model\n'}}
{%- endif -%}
"""

        static let llama: String = """
{{- bos_token }}
{%- if custom_tools is defined %}
    {%- set tools = custom_tools %}
{%- endif %}
{%- if not tools_in_user_message is defined %}
    {%- set tools_in_user_message = true %}
{%- endif %}
{%- if not date_string is defined %}
    {%- if strftime_now is defined %}
        {%- set date_string = strftime_now("%d %b %Y") %}
    {%- else %}
        {%- set date_string = "26 Jul 2024" %}
    {%- endif %}
{%- endif %}
{%- if not tools is defined %}
    {%- set tools = none %}
{%- endif %}

{%- if messages[0]['role'] == 'system' %}
    {%- set system_message = messages[0]['content']|trim %}
    {%- set messages = messages[1:] %}
{%- else %}
    {%- set system_message = "" %}
{%- endif %}

{{- "<|start_header_id|>system<|end_header_id|>\n\n" }}
{%- if tools is not none %}
    {{- "Environment: ipython\n" }}
{%- endif %}
{{- "Cutting Knowledge Date: December 2023\n" }}
{{- "Today Date: " + date_string + "\n\n" }}
{%- if tools is not none and not tools_in_user_message %}
    {{- "You have access to the following functions. To call a function, please respond with JSON for a function call." }}
    {{- 'Respond in the format {"name": function name, "parameters": dictionary of argument name and its value}.' }}
    {{- "Do not use variables.\n\n" }}
    {%- for t in tools %}
        {{- t | tojson(indent=4) }}
        {{- "\n\n" }}
    {%- endfor %}
{%- endif %}
{{- system_message }}
{{- "<|eot_id|>" }}

{%- if tools_in_user_message and not tools is none %}
    {%- if messages | length != 0 %}
        {%- if messages[0]['content'] is string %}
      {%- set first_user_message = messages[0]['content']|trim %}
  {%- else %}
      {%- set first_user_message = messages[0]['content'][0]['text']|trim %}
  {%- endif %}
        {%- set messages = messages[1:] %}
    {%- else %}
        {{- raise_exception("Cannot put tools in the first user message when there's no first user message!") }}
{%- endif %}
    {{- '<|start_header_id|>user<|end_header_id|>\n\n' -}}
    {{- "You are an expert in using functions/tools when necessary. You are given a query and a set of possible functions. "}}
    {{- "Based on the query, call one or more functions to achieve the purpose, if applicable.\n\n"}}
    {{- "If no functions apply, do not call any. Make sure to use any parameters specified as required. "}}
    {{- "If the given query lacks the parameters required by the function, "}}
    {{- "point it out. If a function response is given after you call a function, use it if it answers the query. "}}
    {{- "You should only output function calls in tool call sections.\n\n" }}
    {{- 'Respond in the format {"name": function name, "parameters": dictionary of argument names and their values}. ' }}
    {{- "For number argument values, you do not need to wrap in quotes. If you use quotes, use double quotes. "}}
    {{- "Do not use variables. Here is a list of the only functions you can invoke, in JSON format.\n\n" }}
    {%- for t in tools %}
        {{- t | tojson(indent=4) }}
        {{- "\n\n" }}
    {%- endfor %}
    {{- first_user_message + "<|eot_id|>"}}
{%- endif %}

{%- for message in messages %}
    {%- if not (message.role == 'ipython' or message.role == 'tool' or 'tool_calls' in message) %}
        {{- '<|start_header_id|>' + message['role'] + '<|end_header_id|>\n\n'+ message['content'] | trim + '<|eot_id|>' }}
    {%- elif 'tool_calls' in message %}
        {%- if not message.tool_calls|length == 1 %}
            {{- raise_exception("This model only supports single tool-calls at once!") }}
        {%- endif %}
        {%- set tool_call = message.tool_calls[0].function %}
        {{- '<|start_header_id|>assistant<|end_header_id|>\n\n' -}}
        {{- '{"name": "' + tool_call.name + '", ' }}
        {{- '"parameters": ' }}
        {{- tool_call.arguments | tojson }}
        {{- "}" }}
        {{- "<|eot_id|>" }}
    {%- elif message.role == "tool" or message.role == "ipython" %}
        {{- "<|start_header_id|>ipython<|end_header_id|>\n\n" }}
        {%- if message.content is iterable and message.content is not string %}
            {{- message.content | tojson }}
        {%- else %}
            {{- message.content }}
        {%- endif %}
        {{- "<|eot_id|>" }}
    {%- endif %}
{%- endfor %}
{%- if add_generation_prompt %}
    {{- '<|start_header_id|>assistant<|end_header_id|>\n\n' }}
{%- endif %}
"""

        static let phi3: String = """
{{ '<|system|>Your name is Phi, an AI math expert developed by Microsoft.' }}{% for message in messages %}{% if message['role'] == 'system' %} {{ message['content'] }}{% if 'tools' in message and message['tools'] is not none %}{{ '<|tool|>' + message['tools'] + '<|/tool|>' }}{% endif %}{% endif %}{% endfor %}{{ '<|end|>' }}{% for message in messages %}{% if message['role'] != 'system' %}{{ '<|' + message['role'] + '|>' + message['content'] + '<|end|>' }}{% endif %}{% endfor %}{% if add_generation_prompt %}{{ '<|assistant|>' }}{% else %}{{ eos_token }}{% endif %}
"""
    }
}
