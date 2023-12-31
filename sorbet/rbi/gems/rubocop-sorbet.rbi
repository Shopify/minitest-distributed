# This file is autogenerated. Do not edit it by hand. Regenerate it with:
#   srb rbi gems

# typed: strict
#
# If you would like to make changes to this file, great! Please create the gem's shim here:
#
#   https://github.com/sorbet/sorbet-typed/new/master?filename=lib/rubocop-sorbet/all/rubocop-sorbet.rbi
#
# rubocop-sorbet-0.6.11

module RuboCop
end
module RuboCop::Sorbet
end
class RuboCop::Sorbet::Error < StandardError
end
module RuboCop::Sorbet::Inject
  def self.defaults!; end
end
module RuboCop::Cop
end
module RuboCop::Cop::Sorbet
end
class RuboCop::Cop::Sorbet::BindingConstantWithoutTypeAlias < RuboCop::Cop::Cop
  def autocorrect(node); end
  def binding_unaliased_type?(param0 = nil); end
  def dynamic_type_creation_with_block?(param0 = nil); end
  def generic_parameter_decl_block_call?(param0 = nil); end
  def generic_parameter_decl_call?(param0 = nil); end
  def method_needing_aliasing_on_t?(param0); end
  def not_dynamic_type_creation_with_block?(node); end
  def not_generic_parameter_decl?(node); end
  def not_nil?(node); end
  def not_t_let?(node); end
  def on_casgn(node); end
  def t_let?(param0 = nil); end
  def using_deprecated_type_alias_syntax?(param0 = nil); end
  def using_type_alias?(param0 = nil); end
end
class RuboCop::Cop::Sorbet::ConstantsFromStrings < RuboCop::Cop::Cop
  def constant_from_string?(param0 = nil); end
  def on_send(node); end
end
class RuboCop::Cop::Sorbet::ForbidSuperclassConstLiteral < RuboCop::Cop::Cop
  def not_lit_const_superclass?(param0 = nil); end
  def on_class(node); end
end
class RuboCop::Cop::Sorbet::ForbidIncludeConstLiteral < RuboCop::Cop::Cop
  def autocorrect(node); end
  def initialize(*); end
  def not_lit_const_include?(param0 = nil); end
  def on_send(node); end
  def used_names; end
  def used_names=(arg0); end
end
class RuboCop::Cop::Sorbet::ForbidUntypedStructProps < RuboCop::Cop::Cop
  def on_class(node); end
  def subclass_of_t_struct?(param0 = nil); end
  def t_nilable_untyped(param0 = nil); end
  def t_struct(param0 = nil); end
  def t_untyped(param0 = nil); end
  def untyped_props(param0); end
end
class RuboCop::Cop::Sorbet::OneAncestorPerLine < RuboCop::Cop::Cop
  def abstract?(param0); end
  def autocorrect(node); end
  def more_than_one_ancestor(param0 = nil); end
  def new_ra_line(indent_count); end
  def on_class(node); end
  def on_module(node); end
  def process_node(node); end
  def requires_ancestors(param0); end
end
class RuboCop::Cop::Sorbet::CallbackConditionalsBinding < RuboCop::Cop::Cop
  def autocorrect(node); end
  def on_send(node); end
end
class RuboCop::Cop::Sorbet::ForbidTUnsafe < RuboCop::Cop::Cop
  def on_send(node); end
  def t_unsafe?(param0 = nil); end
end
class RuboCop::Cop::Sorbet::ForbidTUntyped < RuboCop::Cop::Cop
  def on_send(node); end
  def t_untyped?(param0 = nil); end
end
class RuboCop::Cop::Sorbet::TypeAliasName < RuboCop::Cop::Cop
  def casgn_type_alias?(param0 = nil); end
  def on_casgn(node); end
end
class RuboCop::Cop::Sorbet::ForbidExtendTSigHelpersInShims < RuboCop::Cop::Cop
  def autocorrect(node); end
  def extend_t_helpers?(param0 = nil); end
  def extend_t_sig?(param0 = nil); end
  def on_send(node); end
  include RuboCop::Cop::RangeHelp
end
class RuboCop::Cop::Sorbet::ForbidRBIOutsideOfAllowedPaths < RuboCop::Cop::Cop
  def allowed_paths; end
  def investigate(processed_source); end
  include RuboCop::Cop::RangeHelp
end
class RuboCop::Cop::Sorbet::SingleLineRbiClassModuleDefinitions < RuboCop::Cop::Cop
  def autocorrect(node); end
  def convert_newlines(source); end
  def on_class(node); end
  def on_module(node); end
  def process_node(node); end
end
class RuboCop::Cop::Sorbet::AllowIncompatibleOverride < RuboCop::Cop::Cop
  def allow_incompatible?(param0); end
  def allow_incompatible_override?(param0 = nil); end
  def not_nil?(node); end
  def on_send(node); end
  def sig?(param0); end
end
class RuboCop::Cop::Sorbet::SignatureCop < RuboCop::Cop::Cop
  def allowed_recv(recv); end
  def on_block(node); end
  def on_signature(_); end
  def signature?(param0 = nil); end
  def with_runtime?(param0 = nil); end
  def without_runtime?(param0 = nil); end
end
class RuboCop::Cop::Sorbet::CheckedTrueInSignature < RuboCop::Cop::Sorbet::SignatureCop
  def offending_node(param0); end
  def on_signature(node); end
  include RuboCop::Cop::RangeHelp
end
class RuboCop::Cop::Sorbet::KeywordArgumentOrdering < RuboCop::Cop::Sorbet::SignatureCop
  def check_order_for_kwoptargs(parameters); end
  def on_signature(node); end
end
class RuboCop::Cop::Sorbet::SignatureBuildOrder < RuboCop::Cop::Sorbet::SignatureCop
  def autocorrect(node); end
  def call_chain(sig_child_node); end
  def can_autocorrect?; end
  def node_reparsed_with_modern_features(node); end
  def on_signature(node); end
  def root_call(param0); end
end
class RuboCop::Cop::Sorbet::SignatureBuildOrder::ModernBuilder < RuboCop::AST::Builder
end
class RuboCop::Cop::Sorbet::EnforceSignatures < RuboCop::Cop::Sorbet::SignatureCop
  def accessor?(param0 = nil); end
  def autocorrect(node); end
  def check_node(node); end
  def initialize(config = nil, options = nil); end
  def on_def(node); end
  def on_defs(node); end
  def on_send(node); end
  def on_signature(node); end
  def param_type_placeholder; end
  def return_type_placeholder; end
  def scope(node); end
end
class RuboCop::Cop::Sorbet::EnforceSignatures::SigSuggestion
  def generate_params; end
  def generate_return; end
  def initialize(indent, param_placeholder, return_placeholder); end
  def params; end
  def params=(arg0); end
  def returns; end
  def returns=(arg0); end
  def to_autocorrect; end
end
class RuboCop::Cop::Sorbet::ValidSigil < RuboCop::Cop::Cop
  def autocorrect(_node); end
  def check_sigil_present(sigil); end
  def check_strictness_level(sigil, strictness); end
  def check_strictness_not_empty(sigil, strictness); end
  def check_strictness_valid(sigil, strictness); end
  def extract_sigil(processed_source); end
  def extract_strictness(sigil); end
  def investigate(processed_source); end
  def minimum_strictness; end
  def require_sigil_on_all_files?; end
  def suggested_strictness; end
  def suggested_strictness_level(minimum_strictness, suggested_strictness); end
end
class RuboCop::Cop::Sorbet::HasSigil < RuboCop::Cop::Sorbet::ValidSigil
  def require_sigil_on_all_files?; end
end
class RuboCop::Cop::Sorbet::IgnoreSigil < RuboCop::Cop::Sorbet::HasSigil
  def minimum_strictness; end
end
class RuboCop::Cop::Sorbet::FalseSigil < RuboCop::Cop::Sorbet::HasSigil
  def minimum_strictness; end
end
class RuboCop::Cop::Sorbet::TrueSigil < RuboCop::Cop::Sorbet::HasSigil
  def minimum_strictness; end
end
class RuboCop::Cop::Sorbet::StrictSigil < RuboCop::Cop::Sorbet::HasSigil
  def minimum_strictness; end
end
class RuboCop::Cop::Sorbet::StrongSigil < RuboCop::Cop::Sorbet::HasSigil
  def minimum_strictness; end
end
class RuboCop::Cop::Sorbet::EnforceSigilOrder < RuboCop::Cop::Sorbet::ValidSigil
  def autocorrect(_node); end
  def check_magic_comments_order(tokens); end
  def extract_magic_comments(processed_source); end
  def investigate(processed_source); end
  include RuboCop::Cop::RangeHelp
end
class RuboCop::Cop::Sorbet::EnforceSingleSigil < RuboCop::Cop::Sorbet::ValidSigil
  def autocorrect(_node); end
  def extract_all_sigils(processed_source); end
  def investigate(processed_source); end
  include RuboCop::Cop::RangeHelp
end
module RuboCop::Cop::Sorbet::MutableConstantSorbetAwareBehaviour
  def on_assignment(value); end
  def self.prepended(base); end
end
class RuboCop::Cop::Style::MutableConstant < RuboCop::Cop::Base
  def t_let(param0 = nil); end
end
