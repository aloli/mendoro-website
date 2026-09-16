# Générateur du site vitrine d'Erik Pain, géomètre-expert.
#
# Lit les textes AsciiDoc de content/, les convertit en HTML avec asciicrystal,
# les injecte dans les gabarits de templates/ et écrit le site dans _site/.
#
#   shards build --release   # produit bin/build
#   bin/build                # génère _site/
#   bin/build --serve        # génère puis sert sur http://localhost:8765

require "asciicrystal"
require "file_utils"
require "http/server"

module Mendoro
  VERSION = "0.1.0"

  RACINE    = Path[__DIR__].parent
  CONTENU   = RACINE / "content"
  GABARITS  = RACINE / "templates"
  SORTIE    = RACINE / "_site"
  STATIQUES = %w[css images CNAME]

  PORT_LOCAL = 8765

  # Un fichier .adoc découpé en trois : son titre (`= Titre`), ses attributs
  # d'en-tête (`:clef: valeur`) et le corps du document.
  struct Source
    getter titre : String
    getter attributs : Hash(String, String)
    getter corps : String

    def initialize(@titre, @attributs, @corps)
    end

    ATTRIBUT = /\A:([\w-]+):\s*(.*)\z/
    TITRE    = /\A=\s+(.+)\z/

    def self.lire(chemin : Path | String) : Source
      titre = ""
      attributs = {} of String => String
      corps = [] of String
      dans_entete = true

      File.each_line(chemin) do |ligne|
        if dans_entete
          # Les commentaires de ligne servent de notes aux rédacteurs.
          next if ligne.starts_with?("//")

          if m = TITRE.match(ligne)
            titre = m[1].strip
            next
          end

          if m = ATTRIBUT.match(ligne)
            attributs[m[1]] = m[2].strip
            next
          end

          # Une ligne vide en tête n'ouvre le corps que si l'en-tête a commencé.
          next if ligne.blank? && corps.empty?
          dans_entete = false
        end

        corps << ligne
      end

      new(titre, attributs, corps.join('\n').strip)
    end

    # Corps converti en fragment HTML. Sans « standalone => false »,
    # asciicrystal produit un document complet, feuille de style comprise.
    def html : String
      return "" if corps.empty?
      Asciicrystal.convert(corps, {"standalone" => "false"})
    end
  end

  # Remplace les marqueurs {{clef}} d'un gabarit. Un marqueur sans valeur
  # disparaît, ce qui évite de laisser des {{…}} dans la page livrée.
  def self.rendre(gabarit : String, valeurs : Hash(String, String)) : String
    gabarit.gsub(/\{\{([\w-]+)\}\}/) { valeurs[$~[1]]? || "" }
  end

  def self.gabarit(nom : String) : String
    File.read(GABARITS / "#{nom}.html")
  end

  def self.echapper(texte : String) : String
    texte.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;").gsub('"', "&quot;")
  end

  # Un lien s'ouvrant dans un nouvel onglet est signalé par un picto CSS,
  # décoratif et donc muet pour un lecteur d'écran. On y adjoint une mention
  # masquée à l'œil mais lue à voix haute.
  #
  # L'ajout est fait ici plutôt que dans les contenus : compter sur le
  # rédacteur pour l'écrire à chaque lien, c'est accepter qu'il l'oublie.
  LIEN_NOUVEL_ONGLET = /(<a\b[^>]*\btarget="_blank"[^>]*>)(.*?)(<\/a>)/m
  MENTION_MASQUEE    = %(<span class="visually-hidden"> (nouvelle fenêtre)</span>)

  def self.signaler_liens_externes(html : String) : String
    html.gsub(LIEN_NOUVEL_ONGLET) do |entier, m|
      # Ne pas doubler la mention si le rédacteur l'a déjà écrite lui-même.
      m[2].includes?("visually-hidden") ? entier : "#{m[1]}#{m[2]}#{MENTION_MASQUEE}#{m[3]}"
    end
  end

  # ---------------------------------------------------------------- génération

  def self.generer
    site = Source.lire(CONTENU / "site.adoc").attributs
    prestations = charger_prestations

    FileUtils.rm_rf(SORTIE.to_s)
    Dir.mkdir_p(SORTIE.to_s)

    ecrire_accueil(site, prestations)
    ecrire_contact(site, prestations)
    ecrire_mentions(site)
    copier_statiques

    puts "→ #{SORTIE} (#{prestations.size} prestations)"
  end

  def self.charger_prestations : Array(Source)
    dossier = CONTENU / "prestations"
    Dir.glob("#{dossier}/*.adoc").sort.map { |f| Source.lire(f) }
  end

  # Valeurs communes à toutes les pages.
  def self.base(site, page : Source, chemin : String) : Hash(String, String)
    valeurs = {
      "chemin"         => chemin,
      "titre"          => page.titre,
      "intro"          => page.html,
      "page-title"     => page.attributs["page-title"]? || page.titre,
      "page-robots"    => page.attributs["page-robots"]? || "index, follow",
      "og-description" => page.attributs["og-description"]? ||
                          page.attributs["page-description"]? || "",
    } of String => String

    site.each { |clef, valeur| valeurs[clef] = valeur }
    page.attributs.each { |clef, valeur| valeurs[clef] = valeur }
    valeurs
  end

  def self.ecrire_accueil(site, prestations)
    page = Source.lire(CONTENU / "accueil.adoc")

    cartes = prestations.map do |p|
      <<-HTML
            <details class="card">
              <summary>#{echapper(p.titre)}</summary>
              <div class="card-body">
      #{p.html}
              </div>
            </details>
      HTML
    end

    valeurs = base(site, page, "")
    valeurs["corps"] = rendre(gabarit("accueil"),
      {"prestations" => cartes.join("\n")})
    valeurs["pied-gauche-url"] = "contact.html"
    valeurs["pied-gauche-libelle"] = "Contact, information, devis"
    valeurs["pied-droit-url"] = "mentions-legales.html"
    valeurs["pied-droit-libelle"] = "Mentions légales"

    ecrire("index.html", rendre(gabarit("layout"), valeurs))
  end

  def self.ecrire_contact(site, prestations)
    page = Source.lire(CONTENU / "contact.adoc")

    # La liste déroulante reprend exactement les prestations publiées.
    options = prestations.reject { |p| p.titre == "Ma carrière" }.map do |p|
      "            <option>#{echapper(p.titre)}</option>"
    end

    valeurs = base(site, page, "contact.html")
    valeurs["corps"] = rendre(gabarit("contact"), {
      "form-action"     => site["form-action"]? || "https://form.aloli.fr/submit",
      "options-demande" => options.join("\n"),
    })
    valeurs["scripts"] = gabarit("contact-script")
    valeurs["pied-gauche-url"] = "index.html"
    valeurs["pied-gauche-libelle"] = "Retour aux prestations"
    valeurs["pied-droit-url"] = "mentions-legales.html"
    valeurs["pied-droit-libelle"] = "Mentions légales"

    ecrire("contact.html", rendre(gabarit("layout"), valeurs))
  end

  def self.ecrire_mentions(site)
    page = Source.lire(CONTENU / "mentions-legales.adoc")

    # Ici l'intro et le corps viennent du même fichier : le premier paragraphe
    # sert d'introduction, les sections == forment le corps.
    valeurs = base(site, page, "mentions-legales.html")
    valeurs["intro"] = ""
    valeurs["corps"] = rendre(gabarit("mentions-legales"),
      {"contenu" => page.html})
    valeurs["pied-gauche-url"] = "contact.html"
    valeurs["pied-gauche-libelle"] = "Contact, information, devis"
    valeurs["pied-droit-url"] = "index.html"
    valeurs["pied-droit-libelle"] = "Retour aux prestations"

    ecrire("mentions-legales.html", rendre(gabarit("layout"), valeurs))
  end

  def self.copier_statiques
    STATIQUES.each do |entree|
      origine = RACINE / entree
      next unless File.exists?(origine)

      if File.directory?(origine)
        FileUtils.cp_r(origine.to_s, (SORTIE / entree).to_s)
      else
        FileUtils.cp(origine.to_s, (SORTIE / entree).to_s)
      end
    end
  end

  # Le traitement est appliqué à la page entière, et non au seul contenu
  # converti : il couvre ainsi les liens écrits directement dans les gabarits.
  def self.ecrire(nom : String, contenu : String)
    File.write(SORTIE / nom, signaler_liens_externes(contenu))
    puts "   #{nom}"
  end

  # ------------------------------------------------------------ aperçu local

  def self.servir
    serveur = HTTP::Server.new([
      HTTP::LogHandler.new,
      HTTP::StaticFileHandler.new(SORTIE.to_s, directory_listing: false),
    ])
    adresse = serveur.bind_tcp("127.0.0.1", PORT_LOCAL)
    puts "Aperçu sur http://#{adresse} — Ctrl+C pour arrêter."
    serveur.listen
  end
end

Mendoro.generer
Mendoro.servir if ARGV.includes?("--serve")
