#!/usr/bin/env ruby
# coding: utf-8
require 'parslet'
require 'parslet/convenience'

# http://www.ecma-international.org/ecma-262/5.1/#sec-A
class ECMAScriptParser < Parslet::Parser
  # A.1 --
  rule(:source_character) {
    any
  }
  rule(:input_element_div) {
    white_space | line_terminator | comment | token | div_punctuator
  }
  rule(:input_element_reg_exp) {
    white_space | line_terminator | comment | token | regular_expression_literal
  }
  rule(:white_space) {
    tab = 0x9.chr('UTF-8')
    vt = 0xb.chr('UTF-8')
    ff = 0xc.chr('UTF-8')
    sp = 0x20.chr('UTF-8')
    nbsp = 0xa0.chr('UTF-8')
    bom = 0xfeff.chr('UTF-8')
    usp = /\p{Space_Separator}/
    str(tab) | str(vt) | str(ff) | str(sp) | str(nbsp) | str(bom) | match(usp)
  }
  rule(:line_terminator) {
    lf = 0xa.chr('UTF-8')
    cr = 0xd.chr('UTF-8')
    ls = 0x2028.chr('UTF-8')
    ps = 0x2029.chr('UTF-8')
    str(lf) | str(cr) | str(ls) | str(ps)
  }
  rule(:line_terminator_sequence) {
    lf = 0xa.chr('UTF-8')
    cr = 0xd.chr('UTF-8')
    ls = 0x2028.chr('UTF-8')
    ps = 0x2029.chr('UTF-8')
    str(lf) | str(cr) >> str(lf).absent? | str(ls) | str(ps) | str(cr) >> str(lf)
  }
  rule(:comment) {
    multi_line_comment |
      single_line_comment
  }
  rule(:multi_line_comment) {
    str('/*') >> multi_line_comment_chars.maybe >> str('*/')
  }
  rule(:multi_line_comment_chars) {
    multi_line_not_asterisk_char >> multi_line_comment_chars.maybe |
      str('*') >> post_asterisk_comment_chars.maybe
  }
  rule(:post_asterisk_comment_chars) {
    multi_line_not_forward_slash_or_asterisk_char >> multi_line_comment_chars.maybe |
      str('*') >> post_asterisk_comment_chars.maybe
  }
  rule(:multi_line_not_asterisk_char) {
    str('*').absent? >> source_character
  }
  rule(:multi_line_not_forward_slash_or_asterisk_char) {
    (str('/') | str('*')).absent? >> source_character
  }
  rule(:single_line_comment) {
    str('//') >> single_line_comment_chars.maybe
  }
  rule(:single_line_comment_chars) {
    single_line_comment_char >> single_line_comment_chars.maybe
  }
  rule(:single_line_comment_char) {
    line_terminator.absent? >> source_character
  }
  rule(:token) {
    identifier_name |
      punctuator |
      numeric_literal |
      string_literal
  }
  rule(:identifier) {
    identifier_name # but not reserved_word
  }
  rule(:identifier_name) {
    # identifier_start |
    #   identifier_name >> identifier_part
    identifier_start >> identifier_part.repeat
  }
  rule(:identifier_start) {
    unicode_letter |
      str('$') |
      str('_') |
      str("\'") >> unicode_escape_sequence
  }
  rule(:identifier_part) {
    zwnj = 0x200c.chr('UTF-8')
    zwj = 0x200d.chr('UTF-8')
    identifier_start |
      unicode_combining_mark |
      unicode_digit |
      unicode_connector_punctuation |
      str(zwnj) |
      str(zwj)
  }
  rule(:unicode_letter) {
    cats = [/\p{Uppercase_Letter}/, /\p{Lowercase_Letter}/,
            /\p{Titlecase_Letter}/, /\p{Modifier_Letter}/,
            /\p{Other_Letter}/, /\p{Letter_Number}/]
    match(cats.join('|'))
  }
  rule(:unicode_combining_mark) {
    cats = [/\p{Nonspacing_Mark}/, /\p{Combining_Mark}/]
    match(cats.join('|'))
  }
  rule(:unicode_digit) {
    match('\p{Decimal_Number}')
  }
  rule(:unicode_connector_punctuation) {
    match('\p{Connector_Punctuation}')
  }
  rule(:reserved_word) {
    keyword |
      future_reserved_word |
      null_literal |
      boolean_literal
  }
  rule(:keyword) {
    str('break') | str('do') | str('instanceof') | str('typeof') |
      str('case') | str('else') | str('new') | str('var') |
      str('catch') | str('finally') | str('return') | str('void') |
      str('continue') | str('for') | str('switch') | str('while') |
      str('debugger') | str('function') | str('this') | str('with') |
      str('default') | str('if') | str('throw') |
      str('delete') | str('in') | str('try')
  }
  rule(:future_reserved_word) {
    str('class') | str('enum') | str('extends') | str('super') |
      str('const') | str('export') | str('import') |
      # when parsing strict mode
      str('implements') | str('let') | str('private') | str('public') |
      str('interface') | str('package') | str('protected') | str('static') |
      str('yield')
  }
  rule(:punctuator) {
    str('{') | str('}') | str('(') | str(')') | str('[') | str(']') |
      str('.') | str(';') | str(',') | str('<') | str('>') | str('<=') |
      str('>=') | str('==') | str('!=') | str('===') | str('!==') |
      str('+') | str('-') | str('*') | str('%') | str('++') | str('--') |
      str('<<') | str('>>') | str('>>>') | str('&') | str('|') | str('^') |
      str('!') | str('~') | str('&&') | str('||') | str('?') | str(':') |
      str('=') | str('+=') | str('-=') | str('*=') | str('%=') | str('<<=') |
      str('>>=') | str('>>>=') | str('&=') | str('|=') | str('^=')
  }
  rule(:div_punctuator) {
    str('/') | str('/=')
  }
  rule(:literal) {
    null_literal |
      boolean_literal |
      numeric_literal |
      string_literal |
      regular_expression_literal
  }
  rule(:null_literal) {
    str('null')
  }
  rule(:boolean_literal) {
    str('true') |
      str('false')
  }
  rule(:numeric_literal) {
    decimal_literal |
      hex_integer_literal
  }
  rule(:decimal_literal) {
    decimal_integer_literal >> str('.') >> decimal_digits.maybe >> exponent_part.maybe |
      str('.') >> decimal_digits >> exponent_part.maybe |
      decimal_integer_literal >> exponent_part.maybe
  }
  rule(:decimal_integer_literal) {
    str('0') |
      non_zero_digit >> decimal_digits.maybe
  }
  rule(:decimal_digits) {
    decimal_digit |
      # decimal_digits >> decimal_digit
      decimal_digit >> decimal_digits
  }
  rule(:decimal_digit) {
    match(/[0-9]/)
  }
  rule(:non_zero_digit) {
    match(/[1-9]/)
  }
  rule(:exponent_part) {
    exponent_indicator >> signed_integer
  }
  rule(:exponent_indicator) {
    str('e') | str('E')
  }
  rule(:signed_integer) {
    decimal_digits |
      str('+') >> decimal_digits |
      str('-') >> decimal_digits
  }
  rule(:hex_integer_literal) {
    # str('0x') >> hex_digit |
    #   str('0X') >> hex_digit |
    #   hex_integer_literal >> hex_digit
    (str('0x') | str('0X')) >> hex_digit.repeat(1)
  }
  rule(:hex_digit) {
    match(/[0-9a-fA-F]/)
  }
  rule(:string_literal) {
    str('"') >> double_string_characters.maybe >> str('"') |
      str("'") >> single_string_characters.maybe >> str("'")
  }
  rule(:double_string_characters) {
    double_string_character >> double_string_characters.maybe
  }
  rule(:single_string_characters) {
    single_string_character >> single_string_characters.maybe
  }
  rule(:double_string_character) {
    (str('"') | str('\\') | line_terminator).absent? >> source_character |
      str('\\') >> escape_sequence |
      line_continuation
  }
  rule(:single_string_character) {
    (str("'") | str('\\') | line_terminator).absent? >> source_character |
      str('\\') >> escape_sequence |
      line_continuation
  }
  rule(:line_continuation) {
    str('\\') >> line_terminator_sequence
  }
  rule(:escape_sequence) {
    character_escape_sequence |
      str('0') >> decimal_digit.absent? |
      hex_escape_sequence |
      unicode_escape_sequence
  }
  rule(:character_escape_sequence) {
    single_escape_character |
      non_escape_character
  }
  rule(:single_escape_character) {
    str("'") | str('"') | str('\\') | str('b') | str('f') | str('n') | str('r') | str('t') | str('v')
  }
  rule(:non_escape_character) {
    (escape_character | line_terminator).absent? >> source_character
  }
  rule(:escape_character) {
    single_escape_character |
      decimal_digit |
      str('x') |
      str('u')
  }
  rule(:hex_escape_sequence) {
    str('x') >> hex_digit >> hex_digit
  }
  rule(:unicode_escape_sequence) {
    str('u') >> hex_digit >> hex_digit >> hex_digit >> hex_digit
  }
  rule(:regular_expression_literal) {
    str('/') >> regular_expression_body >> str('/') >> regular_expression_flags
  }
  rule(:regular_expression_body) {
    regular_expression_first_char >> regular_expression_chars
  }
  rule(:regular_expression_chars) {
    # str('') |
    #   regular_expression_chars >> regular_expression_char
    regular_expression_char.repeat
  }
  rule(:regular_expression_first_char) {
    (str('*') | str('\\') | str('/') | str('[')).absent? >> regular_expression_non_terminator |
      regular_expression_backslash_sequence |
      regular_expression_class
  }
  rule(:regular_expression_char) {
    (str('\\') | str('/') | str('[')).absent? >> regular_expression_non_terminator |
      regular_expression_backslash_sequence |
      regular_expression_class
  }
  rule(:regular_expression_backslash_sequence) {
    str('\\') >> regular_expression_non_terminator
  }
  rule(:regular_expression_non_terminator) {
    line_terminator.absent? >> source_character
  }
  rule(:regular_expression_class) {
    str('[') >> regular_expression_class_chars >> str(']')
  }
  rule(:regular_expression_class_chars) {
    # str('') |
    #   regular_expression_class_chars >> regular_expression_class_char
    regular_expression_class_char.repeat
  }
  rule(:regular_expression_class_char) {
    (str(']') | str('\\')).absent? >> regular_expression_non_terminator |
      regular_expression_backslash_sequence
  }
  rule(:regular_expression_flags) {
    # str('') |
    #   regular_expression_flags | identifier_part
    identifier_part.repeat
  }
  # -- A.1

  # A.2 --
  rule(:string_numeric_literal) {
    str_white_space.maybe |
      str_white_space.maybe >> str_numeric_literal >> str_white_space.maybe
  }
  rule(:str_white_space) {
    str_white_space_char >> str_white_space.maybe
  }
  rule(:str_white_space_char) {
    white_space |
      line_terminator
  }
  rule(:str_numeric_literal) {
    str_decimal_literal |
      hex_integer_literal
  }
  rule(:str_decimal_literal) {
    str_unsigned_decimal_literal |
      str('+') >> str_unsigned_decimal_literal |
      str('-') >> str_unsigned_decimal_literal
  }
  rule(:str_unsigned_decimal_literal) {
    infinity |
      decimal_digits >> str('.') >> decimal_digits.maybe >> exponent_part.maybe |
      str('.') >> decimal_digits >> exponent_part.maybe |
      decimal_digits >> exponent_part.maybe
  }
  # rule(:decimal_digits) # duplicated
  # rule(:decimal_digit) # duplicated
  # rule(:exponent_part) # duplicated
  # rule(:exponent_indicator) # duplicated
  # rule(:singned_integer) # duplicated
  # rule(:hex_integer_literal) # duplicated
  # rule(:hex_digit) # duplicated
  # -- A.2

  rule(:space) {
    white_space | line_terminator | comment
  }

  # A.3 --
  rule(:primary_expression) {
    str('this') |
      identifier |
      literal |
      array_literal |
      object_literal |
      str('(') >> space.repeat >> expression >> space.repeat >> str(')')
  }
  rule(:array_literal) {
    str('[') >> space.repeat >> elision.maybe >> space.repeat >> str(']') |
      str('[') >> space.repeat >> element_list >> space.repeat >> str(']') |
      str('[') >> space.repeat >> element_list >> space.repeat >> str(',') >> space.repeat >> elision.maybe >> space.repeat >> str(']')
  }
  rule(:element_list) {
    # elision.maybe >> assignment_expression |
    #   element_list >> str(',') >> elision.maybe >> assignment_expression
    elision.maybe >> space.repeat >> assignment_expression >> _element_list
  }
  rule(:_element_list) {
    (str(',') >> space.repeat >> elision.maybe >> space.repeat >> assignment_expression >> space.repeat >> _element_list).maybe
  }
  rule(:elision) {
    # str(',') |
    #   elision >> str(',')
    (str(',') >> space.repeat).repeat(1)
  }
  rule(:object_literal) {
    str('{') >> space.repeat >> str('}') |
      str('{') >> space.repeat >> property_name_and_value_list >> space.repeat >> str('}') |
      str('{') >> space.repeat >> property_name_and_value_list >> space.repeat >> str(',') >> space.repeat >> str('}')
  }
  rule(:property_name_and_value_list) {
    property_assignment |
      # property_name_and_value_list >> str(',') >> property_assignment
      property_assignment >> space.repeat >> str(',') >> space.repeat >> property_name_and_value_list
  }
  rule(:property_assignment) {
    property_name >> space.repeat >> str(':') >> space.repeat >> assignment_expression |
      str('get') >> space.repeat(1) >> property_name >> space.repeat >> str('(') >> space.repeat >> str(')') >> space.repeat >> str('{') >> space.repeat >> function_body >> space.repeat >> str('}') |
      str('set') >> space.repeat(1) >> property_name >> space.repeat >> str('(') >> space.repeat >> property_set_parameter_list >> space.repeat >> str(')') >> space.repeat >> str('{') >> space.repeat >> function_body >> space.repeat >> str('}')
  }
  rule(:property_name) {
    identifier_name |
      string_literal |
      numeric_literal
  }
  rule(:property_set_parameter_list) {
    identifier
  }
  rule(:member_expression) {
    # primary_expression |
    #   function_expression |
    #   member_expression >> str('[') >> expression >> str(']') |
    #   member_expression >> str('.') >> identifier_name |
    #   str('new') >> member_expression >> arguments
    (primary_expression |
     function_expression |
     str('new') >> space.repeat(1) >> member_expression >> space.repeat >> arguments) >> space.repeat >> _member_expression
  }
  rule(:_member_expression) {
    ((str('[') >> space.repeat >> expression >> space.repeat >> str(']') |
      str('.') >> space.repeat >> identifier_name) >> space.repeat >> _member_expression).maybe
  }
  rule(:new_expression) {
    member_expression |
      str('new') >> space.repeat(1) >> new_expression
  }
  rule(:call_expression) {
    # member_expression >> arguments |
    #   call_expression >> arguments |
    #   call_expression >> str('[') >> expression >> str(']') |
    #   call_expression >> str('.') >> identifier_name
    member_expression >> space.repeat >> arguments >> space.repeat >> _call_expression
  }
  rule(:_call_expression) {
    ((arguments | str('[') >> space.repeat >> expression >> space.repeat >> str(']') | str('.') >> space.repeat >> identifier_name) >> space.repeat >> _call_expression).maybe
  }
  rule(:arguments) {
    str('(') >> space.repeat >> str(')') |
      str('(') >> space.repeat >> argument_list >> space.repeat >> str(')')
  }
  rule(:argument_list) {
    # assignment_expression |
    #   argument_list >> str(',') >> assignment_expression
    assignment_expression >> space.repeat >> str(',') >> space.repeat >> argument_list |
      assignment_expression
  }
  rule(:left_hand_side_expression) {
    # new_expression |
    #   call_expression
    call_expression |
      new_expression
  }
  rule(:postfix_expression) {
    # left_hand_side_expression |
    left_hand_side_expression >> (line_terminator.absent? >> space).repeat >> str('++') |
      left_hand_side_expression >> (line_terminator.absent? >> space).repeat >> str('--') |
      left_hand_side_expression

  }
  rule(:unary_expression) {
    postfix_expression |
      str('delete') >> space.repeat(1) >> unary_expression |
      str('void') >> space.repeat(1) >> unary_expression |
      str('typeof') >> space.repeat(1) >> unary_expression |
      str('++') >> space.repeat >> unary_expression |
      str('--') >> space.repeat >> unary_expression |
      str('+') >> space.repeat >> unary_expression |
      str('-') >> space.repeat >> unary_expression |
      str('~') >> space.repeat >> unary_expression |
      str('!') >> space.repeat >> unary_expression
  }
  rule(:multiplicative_expression) {
    # unary_expression |
    #   multiplicative_expression >> str('*') >> unary_expression |
    #   multiplicative_expression >> str('/') >> unary_expression |
    #   multiplicative_expression >> str('%') >> unary_expression
    unary_expression >> space.repeat >> str('*') >> space.repeat >> multiplicative_expression |
      unary_expression >> space.repeat >> str('/') >> space.repeat >> multiplicative_expression |
      unary_expression >> space.repeat >> str('%') >> space.repeat >> multiplicative_expression |
      unary_expression
  }
  rule(:additive_expression) {
    # multiplicative_expression |
    #   additive_expression >> str('+') >> multiplicative_expression |
    #   additive_expression >> str('-') >> multiplicative_expression
    multiplicative_expression >> space.repeat >> str('+') >> space.repeat >> additive_expression |
      multiplicative_expression >> space.repeat >> str('-') >> space.repeat >> additive_expression |
      multiplicative_expression
  }
  rule(:shift_expression) {
    # additive_expression |
    #   shift_expression >> str('<<') >> additive_expression |
    #   shift_expression >> str('>>') >> additive_expression |
    #   shift_expression >> str('>>>') >> additive_expression
    additive_expression >> space.repeat >> str('<<') >> space.repeat >> shift_expression |
      additive_expression >> space.repeat >> str('>>') >> space.repeat >> shift_expression |
      additive_expression >> space.repeat >> str('>>>') >> space.repeat >> shift_expression |
      additive_expression
  }
  rule(:relational_expression) {
    # shift_expression |
    #   relational_expression >> str('<') >> shift_expression |
    #   relational_expression >> str('>') >> shift_expression |
    #   relational_expression >> str('<=') >> shift_expression |
    #   relational_expression >> str('>=') >> shift_expression |
    #   relational_expression >> str('instanceof') >> shift_expression |
    #   relational_expression >> str('in') >> shift_expression
    shift_expression >> space.repeat >> str('<') >> space.repeat >> relational_expression |
      shift_expression >> space.repeat >> str('>') >> space.repeat >> relational_expression |
      shift_expression >> space.repeat >> str('<=') >> space.repeat >> relational_expression |
      shift_expression >> space.repeat >> str('>=') >> space.repeat >> relational_expression |
      shift_expression >> space.repeat(1) >> str('instanceof') >> space.repeat(1) >> relational_expression |
      shift_expression >> space.repeat(1) >> str('in') >> space.repeat(1) >> relational_expression |
      shift_expression
  }
  rule(:relational_expression_no_in) {
    # shift_expression |
    #   relational_expression_no_in >> str('<') >> shift_expression |
    #   relational_expression_no_in >> str('>') >> shift_expression |
    #   relational_expression_no_in >> str('<=') >> shift_expression |
    #   relational_expression_no_in >> str('>=') >> shift_expression |
    #   relational_expression_no_in >> str('instanceof') >> shift_expression |
    #   relational_expression_no_in >> str('in') >> shift_expression
    shift_expression >> space.repeat >> str('<') >> space.repeat >> relational_expression_no_in |
      shift_expression >> space.repeat >> str('>') >> space.repeat >> relational_expression_no_in |
      shift_expression >> space.repeat >> str('<=') >> space.repeat >> relational_expression_no_in |
      shift_expression >> space.repeat >> str('>=') >> space.repeat >> relational_expression_no_in |
      shift_expression >> space.repeat(1) >> str('instanceof') >> space.repeat(1) >> relational_expression_no_in |
      shift_expression
  }
  rule(:equality_expression) {
    # relational_expression |
    #   equality_expression >> str('==') >> relational_expression |
    #   equality_expression >> str('!=') >> relational_expression |
    #   equality_expression >> str('===') >> relational_expression |
    #   equality_expression >> str('!==') >> relational_expression
    relational_expression >> space.repeat >> str('==') >> space.repeat >> equality_expression |
      relational_expression >> space.repeat >> str('!=') >> space.repeat >> equality_expression |
      relational_expression >> space.repeat >> str('===') >> space.repeat >> equality_expression |
      relational_expression >> space.repeat >> str('!==') >> space.repeat >> equality_expression |
      relational_expression
  }
  rule(:equality_expression_no_in) {
    # relational_expression |
    #   equality_expression_no_in >> str('==') >> relational_expression |
    #   equality_expression_no_in >> str('!=') >> relational_expression |
    #   equality_expression_no_in >> str('===') >> relational_expression |
    #   equality_expression_no_in >> str('!==') >> relational_expression
    relational_expression >> space.repeat >> str('==') >> space.repeat >> equality_expression_no_in |
      relational_expression >> space.repeat >> str('!=') >> space.repeat >> equality_expression_no_in |
      relational_expression >> space.repeat >> str('===') >> space.repeat >> equality_expression_no_in |
      relational_expression >> space.repeat >> str('!==') >> space.repeat >> equality_expression_no_in |
      relational_expression
  }
  rule(:bitwise_and_expression) {
    # equality_expression |
    #   bitwise_and_expression >> str('&') >> equality_expression
    equality_expression >> space.repeat >> str('&') >> space.repeat >> bitwise_and_expression |
      equality_expression
  }
  rule(:bitwise_and_expression_no_in) {
    # equality_expression_no_in |
    #   bitwise_and_expression_no_in >> str('&') >> equality_expression_no_in
    equality_expression_no_in >> space.repeat >> str('&') >> space.repeat >> bitwise_and_expression_no_in |
      equality_expression_no_in
  }
  rule(:bitwise_xor_expression) {
    # bitwise_and_expression |
    #   bitwise_xor_expression >> str('^') >> bitwise_and_expression
    bitwise_and_expression >> space.repeat >> str('^') >> space.repeat >> bitwise_xor_expression |
      bitwise_and_expression
  }
  rule(:bitwise_xor_expression_no_in) {
    # bitwise_and_expression_no_in |
    #   bitwise_xor_expression_no_in >> str('^') >> bitwise_and_expression_no_in
    bitwise_and_expression_no_in >> space.repeat >> str('^') >> space.repeat >> bitwise_xor_expression_no_in |
      bitwise_and_expression_no_in
  }
  rule(:bitwise_or_expression) {
    # bitwise_xor_expression |
    #   bitwise_or_expression >> str('|') >> bitwise_xor_expression
    bitwise_xor_expression >> space.repeat >> str('|') >> space.repeat >> bitwise_or_expression |
      bitwise_xor_expression
  }
  rule(:bitwise_or_expression_no_in) {
    # bitwise_xor_expression_no_in |
    #   bitwise_or_expression_no_in >> str('|') >> bitwise_xor_expression_no_in
    bitwise_xor_expression_no_in >> space.repeat >> str('|') >> space.repeat >> bitwise_or_expression_no_in |
      bitwise_xor_expression_no_in
  }
  rule(:logical_and_expression) {
    # bitwise_or_expression |
    #   logical_and_expression >> str('&&') >> bitwise_or_expression
    bitwise_or_expression >> space.repeat >> str('&&') >> space.repeat >> logical_and_expression |
      bitwise_or_expression
  }
  rule(:logical_and_expression_no_in) {
    # bitwise_or_expression_no_in |
    #   logical_and_expression_no_in >> str('&&') >> bitwise_or_expression_no_in
    bitwise_or_expression_no_in >> space.repeat >> str('&&') >> space.repeat >> logical_and_expression_no_in |
      bitwise_or_expression_no_in
  }
  rule(:logical_or_expression) {
    # logical_and_expression |
    #   logical_or_expression >> str('||') >> logical_and_expression
    logical_and_expression >> space.repeat >> str('||') >> space.repeat >> logical_or_expression |
      logical_and_expression
  }
  rule(:logical_or_expression_no_in) {
    # logical_and_expression_no_in |
    #   logical_or_expression_no_in >> str('||') >> logical_and_expression_no_in
    logical_and_expression_no_in >> space.repeat >> str('||') >> space.repeat >> logical_or_expression_no_in |
      logical_and_expression_no_in
  }
  rule(:conditional_expression) {
    # logical_or_expression |
    #   logical_or_expression >> str('?') >> assignment_expression >> str(':') >> assignment_expression
    logical_or_expression >> space.repeat >> str('?') >> space.repeat >> assignment_expression >> space.repeat >> str(':') >> space.repeat >> assignment_expression |
          logical_or_expression
  }
  rule(:conditional_expression_no_in) {
    # logical_or_expression_no_in |
    #   logical_or_expression_no_in >> str('?') >> assignment_expression >> str(':') >> assignment_expression_no_in
    logical_or_expression_no_in >> space.repeat >> str('?') >> space.repeat >> assignment_expression >> space.repeat >> str(':') >> space.repeat >> assignment_expression_no_in |
      logical_or_expression_no_in
  }
  rule(:assignment_expression) {
    conditional_expression |
      left_hand_side_expression >> space.repeat >> str('=') >> space.repeat >> assignment_expression |
      left_hand_side_expression >> space.repeat >> assignment_operator >> space.repeat >> assignment_expression
  }
  rule(:assignment_expression_no_in) {
    conditional_expression_no_in |
      left_hand_side_expression >> space.repeat >> str('=') >> space.repeat >> assignment_expression_no_in |
      left_hand_side_expression >> space.repeat >> assignment_operator >> space.repeat >> assignment_expression_no_in
  }
  rule(:assignment_operator) {
    str('*=') | str('/=') | str('%=') | str('+=') | str('-=') | str('<<=') | str('>>=') | str('>>>=') | str('&=') | str('^=') | str('|=')
  }
  rule(:expression) {
    # assignment_expression |
    #   expression >> str(',') >> assignment_expression
    assignment_expression >> space.repeat >> str(',') >> space.repeat >> expression |
      assignment_expression
  }
  rule(:expression_no_in) {
    # assignment_expression_no_in |
    #   expression_no_in >> str(',') >> assignment_expression
    assignment_expression_no_in >> space.repeat >> str(',') >> space.repeat >> expression_no_in |
      assignment_expression_no_in
  }
  # -- A.3

  # A.4 --
  rule(:statement) {
    block |
      variable_statement |
      empty_statement |
      expression_statement |
      if_statement |
      iteration_statement |
      continue_statement |
      break_statement |
      return_statement |
      with_statement |
      labelled_statement |
      switch_statement |
      throw_statement |
      try_statement |
      debugger_statement
  }
  rule(:block) {
    str('{') >> space.repeat >> statement_list.maybe >> space.repeat >> str('}')
  }
  rule(:statement_list) {
    # statement |
    #   statement_list | statement
    statement >> space.repeat >> statement_list |
      statement
  }
  rule(:variable_statement) {
    str('var') >> space.repeat(1) >> variable_declaration_list >> space.repeat >> str(';')
  }
  rule(:variable_declaration_list) {
    # variable_declaration |
    #   variable_declaration_list >> str(',') >> variable_declaration
    variable_declaration >> space.repeat >> str(',') >> space.repeat >> variable_declaration_list |
      variable_declaration
  }
  rule(:variable_declaration_list_no_in) {
    # variable_declaration_no_in |
    #   variable_declaration_list_no_in >> str(',') >> variable_declaration_no_in
    variable_declaration_no_in >> space.repeat >> str(',') >> space.repeat >> variable_declaration_list_no_in |
      variable_declaration_no_in
  }
  rule(:variable_declaration) {
    identifier >> space.repeat(1) >> initialiser.maybe
  }
  rule(:variable_declaration_no_in) {
    identifier >> space.repeat(1) >> initialiser_no_in.maybe
  }
  rule(:initialiser) {
    str('=') >> space.repeat >> assignment_expression
  }
  rule(:initialiser_no_in) {
    str('=') >> space.repeat >> assignment_expression_no_in
  }
  rule(:empty_statement) {
    str(';')
  }
  rule(:expression_statement) {
    (str(',') | str('function')).absent? >> expression >> space.repeat >> str(';')
  }
  rule(:if_statement) {
    str('if') >> space.repeat >> str('(') >> space.repeat >> expression >> space.repeat >> str(')') >> space.repeat >> statement >> space.repeat >> str('else') >> space.repeat >> statement |
      str('if') >> space.repeat >> str('(') >> space.repeat >> expression >> space.repeat >> str(')') >> space.repeat >> statement
  }
  rule(:iteration_statement) {
    str('do') >> space.repeat >> statement >> space.repeat >> str('while') >> space.repeat >> str('(') >> space.repeat >> expression >> space.repeat >> str(')') >> space.repeat >> str(';') |
      str('while') >> space.repeat >> str('(') >> space.repeat >> expression >> space.repeat >> str(')') >> space.repeat >> statement |
      str('for') >> space.repeat >> str('(') >> space.repeat >> expression_no_in.maybe >> space.repeat >> str(';') >> space.repeat >> expression.maybe >> space.repeat >> str(';') >> space.repeat >> expression.maybe >> space.repeat >> str(';') >> space.repeat >> statement |
      str('for') >> space.repeat >> str('(') >> space.repeat >> str('var') >> space.repeat(1) >> variable_declaration_no_in >> space.repeat >> str(';') >> space.repeat >> expression.maybe >> space.repeat >> str(';') >> space.repeat >> expression.maybe >> space.repeat >> str(')') >> space.repeat >> statement |
      str('for') >> space.repeat >> str('(') >> space.repeat >> left_hand_side_expression >> space.repeat(1) >> str('in') >> space.repeat(1) >> expression >> space.repeat >> str(')') >> space.repeat >> statement |
      str('for') >> space.repeat >> str('(') >> space.repeat >> str('var') >> space.repeat(1) >> variable_declaration_no_in >> space.repeat(1) >> str('in') >> space.repeat(1) >> expression >> space.repeat >> str(')') >> space.repeat >> statement
  }
  rule(:continue_statement) {
    str('continue') >> space.repeat >> str(';') |
      str('continue') >> (line_terminator.absent? >> space).repeat(1) >> identifier >> space.repeat >> str(';')
  }
  rule(:break_statement) {
    str('break') >> space.repeat >> str(';') |
      str('break') >> (line_terminator.absent? >> space).repeat(1) >> identifier >> space.repeat >> str(';')
  }
  rule(:return_statement) {
    str('return') >> space.repeat >> str(';') |
      str('return') >> (line_terminator.absent? >> space).repeat(1) >> expression >> space.repeat >> str(';')
  }
  rule(:with_statement) {
    str('with') >> space.repeat >> str('(') >> space.repeat >> expression >> space.repeat >> str(')') >> space.repeat >> statement
  }
  rule(:switch_statement) {
    str('switch') >> space.repeat >> str('(') >> space.repeat >> expression >> space.repeat >> str(')') >> space.repeat >> case_block
  }
  rule(:case_block) {
    str('{') >> space.repeat >> case_clauses.maybe >> space.repeat >> str('}') |
      str('{') >> space.repeat >> case_clauses.maybe >> space.repeat >> default_clause >> space.repeat >> case_clauses.maybe >> space.repeat >> str('}')
  }
  rule(:case_clauses) {
    case_clause |
      # case_clauses >> case_clause
      case_clause >> space.repeat >> case_clauses
  }
  rule(:case_clouse) {
    str('case') >> space.repeat(1) >> expression >> space.repeat >> str(':') >> space.repeat >> statement_list.maybe
  }
  rule(:default_clause) {
    str('default') >> space.repeat >> str(':') >> space.repeat >> statement_list.maybe
  }
  rule(:labelled_statement) {
    identifier >> space.repeat >> str(':') >> space.repeat >> statement
  }
  rule(:throw_statement) {
    str('throw') >> (line_terminator.absent? >> space).repeat >> expression >> space.repeat >> str(';')
  }
  rule(:try_statement) {
    str('try') >> space.repeat >> block >> space.repeat >> catch |
      str('try') >> space.repeat >> block >> space.repeat >> finally |
      str('try') >> space.repeat >> block >> space.repeat >> catch >> space.repeat >> finally
  }
  rule(:catch) {
    str('catch') >> space.repeat >> str('(') >> space.repeat >> identifier >> space.repeat >> str(')') >> space.repeat >> block
  }
  rule(:finally) {
    str('finally') >> space.repeat >> block
  }
  rule(:debugger_statement) {
    str('debugger') >> space.repeat  >> str(';')
  }
  # -- A.4

  # A.5 --
  rule(:function_declaration) {
    str('function') >> space.repeat(1) >> identifier >> space.repeat >> str('(') >> space.repeat >> formal_parameter_list.maybe >> space.repeat >> str(')') >> space.repeat >> str('{') >> space.repeat >> function_body >> space.repeat >> str('}')
  }
  rule(:function_expression) {
    str('function') >> (space.repeat(1) >> identifier).maybe >> space.repeat >> str('(') >> space.repeat >> formal_parameter_list.maybe >> space.repeat >> str(')') >> space.repeat >> str('{') >> space.repeat >> function_body >> space.repeat >> str('}')
  }
  rule(:formal_parameter_list) {
    # identifier |
    #   formal_parameter_list >> str(',') >> identifier
    identifier >> space.repeat >> str(',') >> space.repeat >> formal_parameter_list |
      identifier
  }
  rule(:function_body) {
    source_elements.maybe
  }
  rule(:program) {
    source_elements.maybe
  }
  rule(:source_elements) {
    # source_element |
    #   source_elements >> source_element
    source_element >> space.repeat >> source_elements |
      source_element
  }
  rule(:source_element) {
    statement |
      function_declaration
  }
  # -- A.5
end

class ECMAScriptExpressionParser < ECMAScriptParser
  root(:cwl_expression)

  rule(:cwl_expression) {
    (str('$(').absent? >> any).repeat.as(:pre) >> str('$(') >> space.repeat >> expression.as(:body) >> space.repeat >> str(')') >> any.repeat.as(:post)
  }
end

class ECMAScriptFunctionBodyParser < ECMAScriptParser
  root(:cwl_function_body)

  rule(:cwl_function_body) {
    (str('${').absent? >> any).repeat.as(:pre) >> str('${') >> space.repeat >> function_body.as(:body) >> space.repeat >> str('}') >> any.repeat.as(:post)
  }
end

def test_exp(str)
  ECMAScriptExpressionParser.new.parse_with_debug(str)
end

def test_fn(str)
  ECMAScriptFunctionBodyParser.new.parse_with_debug(str)
end

if $0 == __FILE__
  # p test_exp(ARGV.empty? ? '$([1,2,3])' : ARGV.first)
  # p test_fn(ARGV.empty? ? '${ var r = 24; return r; }' : ARGV.first)
  ret = test_exp(ARGV.empty? ? '$([1,2,3])' : ARGV.first)
  p ret[:pre].class
  p ret[:body].class
  p ret[:post].class
end
