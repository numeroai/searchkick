# lives on the :secondary cluster registered in test_helper
# index_prefix keeps its indices distinct from Product's, since CI runs both
# clusters against the same server
class AltProduct
  searchkick cluster: :secondary, index_prefix: "alt"
end
