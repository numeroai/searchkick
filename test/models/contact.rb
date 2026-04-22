class Contact
  searchkick \
    text_start: [:name, :email],
    text_middle: [:name, :email],
    text_end: [:name, :email],
    word_start: [:name, :email],
    word_middle: [:name, :email],
    word_end: [:name, :email]
    

  def search_data
    search_name.merge(search_email)
  end

  def search_name
    {name: name}
  end

  def search_email
    {email: email}
  end
end