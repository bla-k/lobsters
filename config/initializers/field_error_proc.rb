ActionView::Base.field_error_proc = ->(html_tag, _instance) {
  fragment = Nokogiri::HTML5.fragment(html_tag)
  fragment.children.each do |node|
    next unless node.element?
    classes = (node["class"] || "").split
    classes << "field_with_errors" unless classes.include?("field_with_errors")
    node["class"] = classes.join(" ")
  end
  fragment.to_html.html_safe
}
